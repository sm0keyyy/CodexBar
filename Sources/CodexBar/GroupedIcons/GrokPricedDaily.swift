import CodexBarCore
import Foundation

enum GrokPricedDaily {
    static func entries(native: [String: GrokDayCost], mirrors: CostUsageDailyReport) -> [CostUsageDailyReport.Entry] {
        let entries = native.keys.sorted().compactMap { day -> CostUsageDailyReport.Entry? in
            guard let cost = native[day] else { return nil }
            let models = Set(cost.modelUSD.keys).union(cost.unpricedModels).sorted()
            return .init(
                date: day,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: Int(cost.totalTokens),
                requestCount: cost.requestCount,
                costUSD: cost.modelUSD.isEmpty ? nil : cost.usd,
                modelsUsed: models,
                modelBreakdowns: models.map { .init(modelName: $0, costUSD: cost.modelUSD[$0]) },
                estimatedRequestCount: cost.estimated ? cost.requestCount : nil)
        }
        return CostUsageDailyReport(data: entries, summary: nil).merged(with: mirrors).data
    }

    static func applying(
        _ priced: [CostUsageDailyReport.Entry]?,
        to snapshot: CostUsageTokenSnapshot?,
        now: Date = Date(),
        calendar: Calendar = .current) -> CostUsageTokenSnapshot?
    {
        guard let priced else { return snapshot }
        guard snapshot != nil || !priced.isEmpty else { return nil }
        var byDay = Dictionary(uniqueKeysWithValues: (snapshot?.daily ?? []).map { ($0.date, self.unpriced($0)) })
        for entry in priced {
            byDay[entry.date] = entry
        }
        let daily = byDay.values.sorted { $0.date < $1.date }
        let today = CostUsageTokenSnapshot.entry(in: daily, forLocalDayContaining: now, calendar: calendar)
        let tokens = daily.compactMap(\.totalTokens)
        let requests = daily.compactMap(\.requestCount)
        let costs = daily.compactMap(\.costUSD)
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: today?.costUSD,
            sessionRequests: today?.requestCount,
            last30DaysTokens: tokens.isEmpty ? nil : CheckedSum.integers(tokens),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            last30DaysRequests: requests.isEmpty ? nil : CheckedSum.integers(requests),
            currencyCode: "USD",
            historyDays: max(30, snapshot?.historyDays ?? 30),
            historyCoverageIsEstablished: snapshot?.historyCoverageIsEstablished ?? true,
            historyScanIsPartial: snapshot?.historyScanIsPartial ?? false,
            historyLabel: snapshot?.historyLabel,
            costProvenance: .listPriceEstimate,
            credentialScopeFingerprint: snapshot?.credentialScopeFingerprint,
            daily: daily,
            projects: snapshot?.projects ?? [],
            sessions: snapshot?.sessions ?? [],
            detailsAreComplete: snapshot?.detailsAreComplete ?? false,
            hourly: snapshot?.hourly ?? [],
            quotaSlices: snapshot?.quotaSlices ?? [],
            updatedAt: now)
    }

    private static func unpriced(_ entry: CostUsageDailyReport.Entry) -> CostUsageDailyReport.Entry {
        .init(
            date: entry.date,
            inputTokens: entry.inputTokens,
            outputTokens: entry.outputTokens,
            cacheReadTokens: entry.cacheReadTokens,
            cacheCreationTokens: entry.cacheCreationTokens,
            reasoningTokens: entry.reasoningTokens,
            totalTokens: entry.totalTokens,
            requestCount: entry.requestCount,
            costUSD: nil,
            modelsUsed: entry.modelsUsed,
            modelBreakdowns: entry.modelBreakdowns?.map {
                .init(modelName: $0.modelName, costUSD: nil, totalTokens: $0.totalTokens, requestCount: $0.requestCount)
            },
            unpricedRequestCount: entry.requestCount)
    }
}
