import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct GrokPricedDailyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_793_649_600)
    }

    private func day(_ offset: Int) -> Date {
        self.calendar.date(byAdding: .day, value: offset, to: self.now)!
    }

    private func key(_ date: Date) -> String {
        GrokLocalSessionScanner.dayKey(for: date, calendar: self.calendar)!
    }

    private func request(_ date: Date, model: String = "grok-4.7", id: String = "native") -> String {
        """
        {"msg":"model changed","sid":"\(id)","ctx":{"model":"\(model)"}}
        {"msg":"shell.turn.inference_done","sid":"\(id)","ts":"\(date.ISO8601Format())",\
        "ctx":{"prompt_tokens":100000,"cached_prompt_tokens":50000,"completion_tokens":10000}}
        """
    }

    private func entry(_ date: Date, cost: Double?, model: String = "grok-4.7") -> CostUsageDailyReport.Entry {
        .init(
            date: self.key(date),
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 100,
            requestCount: 1,
            costUSD: cost,
            modelsUsed: [model],
            modelBreakdowns: [.init(modelName: model, costUSD: cost, totalTokens: 100, requestCount: 1)])
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func `native and mirrored days share the exact pill amount and window sums`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let log = [0, -1, -8, -30].map { self.request(self.day($0)) }.joined(separator: "\n")
        try self.write(log, to: env.root.appendingPathComponent("logs/unified.jsonl"))
        let mirrors = CostUsageDailyReport(data: [
            self.entry(self.day(-2), cost: 0.5), self.entry(self.now, cost: 1.23),
            self.entry(self.day(-30), cost: 99),
        ], summary: nil)
        let scan = try GrokDailyCostCache.scan(
            home: env.root, now: self.now, calendar: self.calendar, previousSignature: nil, mirrors: mirrors)
        let daily = try #require(scan.daily)
        #expect(daily.map(\.date) == [-8, -2, -1, 0].map { self.key(self.day($0)) })
        let today = try #require(daily.last)
        #expect(today.costUSD == scan.cost?.usd)
        #expect(abs((today.costUSD ?? 0) - 1.415) < 1e-8)
        #expect(today.modelBreakdowns?.first?.costUSD == today.costUSD)
        let snapshot = try #require(GrokPricedDaily.applying(
            daily, to: nil, now: self.now, calendar: self.calendar))
        #expect(snapshot.sessionCostUSD == scan.cost?.usd)
        #expect(abs((snapshot.summary(forLastDays: 7, calendar: self.calendar).totalCostUSD ?? 0) - 2.1) < 1e-8)
        #expect(abs((snapshot.last30DaysCostUSD ?? 0) - 2.285) < 1e-8)
        #expect(snapshot.last30DaysCostUSD == daily.compactMap(\.costUSD).reduce(0, +))
        #expect(snapshot.summary(forLastDays: 30, calendar: self.calendar).totalCostUSD == snapshot.last30DaysCostUSD)
    }

    @Test func `unknown only days stay unpriced and mixed days retain priced subtotals`() {
        let log = [
            self.request(self.day(-1), model: "grok-test-unknown", id: "unknown"),
            self.request(self.now, model: "grok-test-unknown", id: "mixed-unknown"),
            self.request(self.now, id: "mixed-priced"),
        ].joined(separator: "\n")
        let native = GrokSessionCost.daily(
            unifiedLog: log,
            sessions: [],
            now: self.now,
            calendar: self.calendar,
            days: 30,
            pricing: .init(catalog: nil))
        let daily = GrokPricedDaily.entries(native: native, mirrors: .init(data: [], summary: nil))
        #expect(daily.count == 2)
        #expect(daily.first?.costUSD == nil)
        #expect(daily.first?.modelBreakdowns == [.init(modelName: "grok-test-unknown", costUSD: nil)])
        #expect(abs((daily.last?.costUSD ?? 0) - 0.185) < 1e-8)
        #expect(daily.last?.modelsUsed == ["grok-4.7", "grok-test-unknown"])
        #expect(daily.last?.modelBreakdowns?.first { $0.modelName == "grok-test-unknown" }?.costUSD == nil)
    }

    @Test func `past day mirror changes invalidate the full daily series`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let first = try GrokDailyCostCache.scan(
            home: env.root,
            now: self.now,
            calendar: self.calendar,
            previousSignature: nil,
            mirrors: .init(data: [self.entry(self.day(-8), cost: 1)], summary: nil))
        let changed = try GrokDailyCostCache.scan(
            home: env.root,
            now: self.now,
            calendar: self.calendar,
            previousSignature: first.signature,
            mirrors: .init(data: [self.entry(self.day(-8), cost: 2)], summary: nil),
            sessionCache: first.sessionCache)
        #expect(changed.daily?.first?.costUSD == 2)
        #expect(changed.cost?.usd == 0)
        let unchanged = try GrokDailyCostCache.scan(
            home: env.root,
            now: self.now,
            calendar: self.calendar,
            previousSignature: changed.signature,
            mirrors: .init(data: [self.entry(self.day(-8), cost: 2)], summary: nil),
            sessionCache: changed.sessionCache)
        #expect(unchanged.daily == nil)
        #expect(unchanged.cost == nil)
    }

    @Test func `native session cache reuses parsed rollups and invalidates changed file stamps`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let session = env.root.appendingPathComponent("sessions/project/session")
        let summary = session.appendingPathComponent("summary.json")
        try self.write("""
        {"info":{"id":"session"},"updated_at":"\(self.day(-8).ISO8601Format())","current_model_id":"grok-4.7"}
        """, to: summary)
        try FileManager.default.setAttributes([.modificationDate: self.day(-8)], ofItemAtPath: summary.path)
        let updates = session.appendingPathComponent("updates.jsonl")
        func usage(_ input: Int) -> String {
            """
            {"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":\(input)}}}}
            """
        }
        try self.write(usage(1000), to: updates)
        let mirrors = CostUsageDailyReport(data: [], summary: nil)
        let first = try GrokDailyCostCache.scan(
            home: env.root, now: self.now, calendar: self.calendar, previousSignature: nil, mirrors: mirrors)
        #expect(first.daily?.first?.costUSD == 0.002)
        #expect(first.parsedSessionCount == 1)
        let reused = try GrokDailyCostCache.scan(
            home: env.root,
            now: self.now,
            calendar: self.calendar,
            previousSignature: first.signature,
            mirrors: .init(data: [self.entry(self.now, cost: 1)], summary: nil),
            sessionCache: first.sessionCache)
        #expect(reused.parsedSessionCount == 0)
        #expect(reused.daily?.first?.costUSD == 0.002)
        try self.write(usage(2000), to: updates)
        let changed = try GrokDailyCostCache.scan(
            home: env.root,
            now: self.now,
            calendar: self.calendar,
            previousSignature: first.signature,
            mirrors: mirrors,
            sessionCache: reused.sessionCache)
        #expect(changed.parsedSessionCount == 1)
        #expect(changed.daily?.first?.costUSD == 0.004)
        try Data([0xFF]).write(to: updates)
        #expect(throws: (any Error).self) {
            try GrokDailyCostCache.scan(
                home: env.root,
                now: self.now,
                calendar: self.calendar,
                previousSignature: changed.signature,
                mirrors: mirrors,
                sessionCache: changed.sessionCache)
        }
        try FileManager.default.setAttributes([.modificationDate: self.day(-31)], ofItemAtPath: summary.path)
        let outside = try GrokDailyCostCache.scan(
            home: env.root,
            now: self.now,
            calendar: self.calendar,
            previousSignature: changed.signature,
            mirrors: mirrors,
            sessionCache: changed.sessionCache)
        #expect(outside.daily?.isEmpty == true)
    }

    @Test func `priced snapshots supply all three subscriptions to the overview`() throws {
        let grok = try #require(GrokPricedDaily.applying(
            [self.entry(self.now, cost: 7.96)], to: nil, now: self.now, calendar: self.calendar))
        let inputs: [SpendDashboardModel.ProviderInput] = try [
            .init(
                provider: .codex,
                displayName: "Codex",
                snapshot: #require(GrokPricedDaily.applying(
                    [self.entry(self.now, cost: 37.54, model: "gpt-test")],
                    to: nil,
                    now: self.now,
                    calendar: self.calendar))),
            .init(
                provider: .claude,
                displayName: "Claude",
                snapshot: #require(GrokPricedDaily.applying(
                    [self.entry(self.now, cost: 25.11, model: "claude-test")],
                    to: nil,
                    now: self.now,
                    calendar: self.calendar))),
            .init(provider: .grok, displayName: "Grok", snapshot: grok),
        ]
        let model = SpendDashboardModel.build(inputs: inputs, requestedDays: 30, now: self.now, calendar: self.calendar)
        let summary = OverviewSpendSummary(model: model, providerCount: 3)
        #expect(summary.providerCoverageText == "3 of 3 subscriptions have spend")
        #expect(!summary.isPartial)
    }

    @Test @MainActor func `daily revisions republish once per store before narrower projections`() throws {
        let now = Date()
        let calendar = Calendar.current
        let day = try #require(GrokLocalSessionScanner.dayKey(for: now, calendar: calendar))
        let older = try #require(calendar.date(byAdding: .day, value: -8, to: now))
        let olderDay = try #require(GrokLocalSessionScanner.dayKey(for: older, calendar: calendar))
        let cache = GrokDailyCostCache()
        cache.clearForNewDay(now: now, calendar: calendar)
        let settings = testSettingsStore(
            suiteName: "GrokPricedDailyTests",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(
                homeDirectory: "/nonexistent", cacheTTL: 0, fileExists: { _ in false }, directoryContents: { _ in [] }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let raw = CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: nil,
            last30DaysTokens: 100,
            last30DaysCostUSD: nil,
            daily: [],
            updatedAt: now)
        store.snapshots[.grok] = UsageSnapshot(primary: nil, secondary: nil, costUsage: raw, updatedAt: now)
        for _ in 0..<2 {
            _ = store.grokLocalTokenSnapshot(from: store.snapshot(for: .grok), historyDays: 30, cache: cache)
        }
        func priced(_ date: String, _ cost: Double) -> CostUsageDailyReport.Entry {
            .init(
                date: date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 100,
                requestCount: 1,
                costUSD: cost,
                modelsUsed: ["grok-4.7"],
                modelBreakdowns: [.init(
                    modelName: "grok-4.7",
                    costUSD: cost)])
        }
        cache.today = GrokDayCost(usd: 1.23)
        cache.daily = [priced(olderDay, 2), priced(day, 1.23)]
        #expect(cache.dailyRevision == 1)
        #expect(store.tokenSnapshotPublications[.grok]?.snapshot?.sessionCostUSD == cache.today?.usd)
        #expect(store.tokenSnapshotPublications[.grok]?.snapshot?.last30DaysCostUSD == 3.23)
        let revision = store.tokenSnapshotPublicationRevision(for: .grok)
        cache.daily = [priced(olderDay, 2), priced(day, 1.23)]
        #expect(cache.dailyRevision == 1)
        #expect(store.tokenSnapshotPublicationRevision(for: .grok) == revision)
        let week = try #require(store.grokLocalTokenSnapshot(
            from: store.snapshot(for: .grok), historyDays: 7, cache: cache))
        #expect(week.daily.map(\.date) == [day])
        #expect(week.last30DaysCostUSD == 1.23)
        #expect(week.sessionCostUSD == cache.today?.usd)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        cache.clearForNewDay(now: tomorrow, calendar: calendar)
        #expect(cache.today == nil)
        #expect(cache.daily == nil)
        #expect(cache.dailyRevision == 2)
    }
}
