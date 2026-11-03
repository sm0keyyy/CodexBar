import CodexBarCore
import Foundation

extension UsageStore {
    func grokLocalTokenSnapshot(
        from providerSnapshot: UsageSnapshot?,
        historyDays: Int,
        cache: GrokDailyCostCache = .shared) -> CostUsageTokenSnapshot?
    {
        cache.installRepublisher(for: self) { [weak self, weak cache] in
            guard let cache else { return }
            self?.republishGrokPricedTokenSnapshot(cache: cache)
        }
        let source = providerSnapshot?.costUsage
            ?? (providerSnapshot == nil ? self.tokenSnapshotPublications[.grok]?.snapshot : nil)
        guard let published = GrokPricedDaily.applying(cache.daily, to: source) else { return nil }
        let days = max(1, historyDays)
        // Wider views retain the scan's actual coverage; only narrower views need projection.
        guard days < published.historyDays else { return published }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: published.updatedAt)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let firstDay = GrokLocalSessionScanner.dayKey(for: start, calendar: calendar),
              let lastDay = GrokLocalSessionScanner.dayKey(for: today, calendar: calendar)
        else { return nil }
        let daily = published.daily.filter { $0.date >= firstDay && $0.date <= lastDay }
        guard !daily.isEmpty else { return nil }
        let tokens = daily.compactMap(\.totalTokens)
        let requests = daily.compactMap(\.requestCount)
        let costs = daily.compactMap(\.costUSD)

        return CostUsageTokenSnapshot(
            sessionTokens: published.sessionTokens,
            sessionCostUSD: published.sessionCostUSD,
            sessionRequests: published.sessionRequests,
            last30DaysTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            last30DaysRequests: requests.isEmpty ? nil : requests.reduce(0, +),
            currencyCode: published.currencyCode,
            historyDays: days,
            historyCoverageIsEstablished: published.historyCoverageIsEstablished,
            historyLabel: published.historyLabel,
            meteredCostUSD: published.meteredCostUSD,
            costProvenance: published.costProvenance,
            credentialScopeFingerprint: published.credentialScopeFingerprint,
            daily: daily,
            projects: published.projects,
            sessions: published.sessions,
            hourly: published.hourly,
            quotaSlices: published.quotaSlices,
            updatedAt: published.updatedAt)
    }

    func republishGrokPricedTokenSnapshot(cache: GrokDailyCostCache = .shared) {
        let snapshot = self.grokLocalTokenSnapshot(
            from: self.snapshot(for: .grok),
            historyDays: self.settings.costUsageHistoryDays,
            cache: cache)
        if let snapshot {
            self.publishTokenSnapshot(snapshot, for: .grok)
        } else {
            self.publishConfirmedEmptyTokenSnapshot(for: .grok)
        }
    }

    func loadGrokLocalTokenSnapshot(historyDays: Int) async throws -> CostUsageTokenSnapshot? {
        let summary = try await GrokLocalSessionScanner.summarizeOffMainThread(
            env: self.environmentBase,
            lookbackDays: historyDays)
        return summary.toCostUsageTokenSnapshot(historyDays: historyDays)
    }
}
