import CodexBarCore
import Foundation

extension PlanUtilizationHistoryBuckets {
    /// Identityless legacy buckets can only join the contiguous tail selected at the credential cutover.
    mutating func migrateClaudeOAuthFragments() {
        let prefix = "__claude_oauth__:"
        guard let preferred = self.preferredAccountKey, preferred.hasPrefix(prefix) else { return }
        let cutover = self.accounts.filter { !$0.key.hasPrefix(prefix) }
            .values.flatMap(\.self).compactMap(\.latestCapturedAt).max() ?? .distantPast
        let fragments = self.accounts.compactMap { key, histories -> ClaudeOAuthHistoryFragment? in
            guard key.hasPrefix(prefix), let fragment = ClaudeOAuthHistoryFragment(key: key, histories: histories),
                  fragment.first >= cutover else { return nil }
            return fragment
        }.sorted { $0.first == $1.first ? $0.key < $1.key : $0.first < $1.first }
        guard let selectedIndex = fragments.firstIndex(where: { $0.key == preferred }),
              selectedIndex == fragments.count - 1 else { return }
        var firstIndex = selectedIndex
        while firstIndex > 0, fragments[firstIndex - 1].canPrecede(fragments[firstIndex]) {
            firstIndex -= 1
        }
        guard firstIndex < selectedIndex else { return }
        let merged = Self.canonicalClaudeOAuthHistories(fragments[firstIndex...].flatMap(\.histories))
        for fragment in fragments[firstIndex...] where fragment.key != preferred {
            self.accounts.removeValue(forKey: fragment.key)
            self.moveSessionEquivalentWindowPairIdentity(from: fragment.key, to: preferred)
        }
        self.setHistories(merged, for: preferred)
    }

    private static func canonicalClaudeOAuthHistories(
        _ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory]
    {
        struct SeriesKey: Hashable {
            let name: PlanUtilizationSeriesName
            let minutes: Int
        }
        var series: [SeriesKey: [Int64: PlanUtilizationHistoryEntry]] = [:]
        for history in histories {
            let key = SeriesKey(name: history.name, minutes: history.name.canonicalWindowMinutes(history.windowMinutes))
            for entry in history.entries {
                let hour = UsageStore.planUtilizationHourBucket(for: entry.capturedAt)
                if let previous = series[key]?[hour],
                   !PlanUtilizationHistoryEntry.precedes(previous, entry) { continue }
                series[key, default: [:]][hour] = entry
            }
        }
        return series.map { key, hours in
            PlanUtilizationSeriesHistory(
                name: key.name,
                windowMinutes: key.minutes,
                entries: Array(hours.values.sorted(by: PlanUtilizationHistoryEntry.precedes)
                    .suffix(UsageStore.planUtilizationMaxSamples)))
        }.sorted(by: PlanUtilizationSeriesHistory.precedes)
    }
}

private struct ClaudeOAuthHistoryFragment {
    let key: String
    let histories: [PlanUtilizationSeriesHistory]
    let first: Date
    let last: Date

    init?(key: String, histories: [PlanUtilizationSeriesHistory]) {
        guard let first = histories.compactMap({ $0.entries.first?.capturedAt }).min(),
              let last = histories.compactMap(\.latestCapturedAt).max()
        else { return nil }
        self.key = key
        self.histories = histories
        self.first = first
        self.last = last
    }

    func canPrecede(_ next: Self) -> Bool {
        // A half-day gap covers a renewal or a sleeping laptop, not disconnected account history.
        guard self.last < next.first, next.first.timeIntervalSince(self.last) <= 12 * 3600,
              let weekly = self.histories.first(where: { $0.name == .weekly }),
              let nextWeekly = next.histories.first(where: { $0.name == .weekly }),
              weekly.name.canonicalWindowMinutes(weekly.windowMinutes)
              == nextWeekly.name.canonicalWindowMinutes(nextWeekly.windowMinutes),
              UsageStore.areEquivalentPlanUtilizationResetBoundaries(
                  weekly.entries.last?.resetsAt, nextWeekly.entries.first?.resetsAt)
        else { return false }
        for history in self.histories {
            guard let following = next.histories.first(where: {
                $0.name == history.name
                    && $0.name.canonicalWindowMinutes($0.windowMinutes)
                    == history.name.canonicalWindowMinutes(history.windowMinutes)
            }) else { continue }
            guard let reset = history.entries.last(where: { $0.resetsAt != nil })?.resetsAt,
                  let nextReset = following.entries.first(where: { $0.resetsAt != nil })?.resetsAt
            else { return false }
            // An expired session can restart between polls. An active window must retain its reset boundary.
            if reset > next.first,
               !UsageStore.areEquivalentPlanUtilizationResetBoundaries(reset, nextReset)
            { return false }
        }
        return true
    }
}
