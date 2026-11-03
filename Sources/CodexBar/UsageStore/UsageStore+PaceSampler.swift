import CodexBarCore
import Foundation

extension UsageStore {
    var isPaceSamplerActive: Bool {
        PaceMode.isActive(settings: self.settings, store: self)
    }

    func paceSamplerSamples(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        capturedAt: Date,
        excluding existing: [PlanUtilizationSeriesSample]) -> [PlanUtilizationSeriesSample]
    {
        guard self.isPaceSamplerActive else { return [] }
        var samples: [PlanUtilizationSeriesSample] = []

        func append(_ window: RateWindow?, name: PlanUtilizationSeriesName, minutes: Int? = nil) {
            guard let window, !window.isSyntheticPlaceholder, window.usedPercent.isFinite,
                  let minutes = minutes ?? window.windowMinutes, minutes > 0
            else { return }
            let canonicalMinutes = name.canonicalWindowMinutes(minutes)
            guard !existing.contains(where: {
                $0.name == name && name.canonicalWindowMinutes($0.windowMinutes) == canonicalMinutes
            }), !samples.contains(where: { $0.name == name && $0.windowMinutes == canonicalMinutes })
            else { return }
            samples.append(PlanUtilizationSeriesSample(
                name: name,
                windowMinutes: canonicalMinutes,
                entry: PlanUtilizationHistoryEntry(
                    capturedAt: capturedAt,
                    usedPercent: UsagePercent(raw: window.usedPercent).displayClamped,
                    resetsAt: window.resetsAt)))
        }

        func appendStandard(_ window: RateWindow?, id: String) {
            guard let window else { return }
            append(
                window,
                name: PaceHistorySeries.name(provider: provider, windowID: id, window: window, now: capturedAt),
                minutes: PaceHistorySeries.sampleDurationMinutes(
                    window: window, windowID: id, provider: provider, now: capturedAt))
        }
        appendStandard(snapshot.primary, id: "primary")
        appendStandard(snapshot.secondary, id: "secondary")
        appendStandard(snapshot.tertiary, id: "tertiary")
        for extra in snapshot.extraRateWindows ?? [] where extra.usageKnown {
            append(extra.window, name: PlanUtilizationSeriesName(rawValue: "extra:\(extra.id)"))
        }
        return samples
    }

    nonisolated static func updatedPaceSamplerHistories(
        existingHistories: [PlanUtilizationSeriesHistory],
        samples: [PlanUtilizationSeriesSample]) -> [PlanUtilizationSeriesHistory]?
    {
        var histories = self.updatedPlanUtilizationHistories(
            existingHistories: existingHistories, samples: samples) ?? existingHistories
        for index in histories.indices {
            let history = histories[index]
            guard let duplicate = history.entries.indices.dropFirst().first(where: {
                self.planUtilizationHourBucket(for: history.entries[$0 - 1].capturedAt)
                    == self.planUtilizationHourBucket(for: history.entries[$0].capturedAt)
            }) else { continue }
            var entries = Array(history.entries[..<duplicate])
            for entry in history.entries[duplicate...] {
                if let last = entries.last,
                   self.planUtilizationHourBucket(for: last.capturedAt)
                   == self.planUtilizationHourBucket(for: entry.capturedAt)
                {
                    entries[entries.count - 1] = entry
                } else {
                    entries.append(entry)
                }
            }
            histories[index] = PlanUtilizationSeriesHistory(
                name: history.name, windowMinutes: history.windowMinutes, entries: entries)
        }
        return histories == existingHistories ? nil : histories
    }

    nonisolated static func paceSamplerPersistenceBoundary(
        histories: [PlanUtilizationSeriesHistory],
        samples: [PlanUtilizationSeriesSample]) -> (completedHour: Bool, reset: Bool)
    {
        var completedHour = false
        for sample in samples {
            guard let previous = histories.first(where: {
                $0.name == sample.name && $0.windowMinutes == sample.windowMinutes
            })?.entries.last else {
                if histories.contains(where: { $0.name == sample.name }) { return (completedHour, true) }
                continue
            }
            if self.haveMeaningfullyDifferentResetBoundaries(previous.resetsAt, sample.entry.resetsAt) {
                return (completedHour, true)
            }
            if self.planUtilizationHourBucket(for: previous.capturedAt)
                != self.planUtilizationHourBucket(for: sample.entry.capturedAt)
            {
                completedHour = true
            }
        }
        return (completedHour, false)
    }

    /// The live history already holds the one pending sample per window; no second buffer is needed.
    nonisolated static func completedPaceSamplerSnapshot(
        _ snapshot: [ProviderInstanceID: PlanUtilizationHistoryBuckets],
        now: Date) -> [ProviderInstanceID: PlanUtilizationHistoryBuckets]
    {
        let hour = self.planUtilizationHourBucket(for: now)
        func completed(_ histories: [PlanUtilizationSeriesHistory]) -> [PlanUtilizationSeriesHistory] {
            histories.compactMap { history in
                guard let last = history.entries.last,
                      self.planUtilizationHourBucket(for: last.capturedAt) == hour
                else { return history }
                let entries = history.entries.dropLast()
                guard !entries.isEmpty else { return nil }
                return PlanUtilizationSeriesHistory(
                    name: history.name, windowMinutes: history.windowMinutes, entries: Array(entries))
            }
        }
        return snapshot.mapValues { buckets in
            var buckets = buckets
            buckets.unscoped = completed(buckets.unscoped)
            buckets.accounts = buckets.accounts.mapValues(completed)
            return buckets
        }
    }

    func persistPlanUtilizationHistoryForTermination() -> Task<Void, Never>? {
        guard self.planUtilizationHistoryLoaded, !self.planUtilizationHistory.isEmpty else { return nil }
        let snapshot = self.planUtilizationHistory
        let coordinator = self.planUtilizationPersistenceCoordinator
        let coalescingPaceSamples = self.isPaceSamplerActive
        return Task { await coordinator.flush(snapshot, coalescingPaceSamples: coalescingPaceSamples) }
    }
}
