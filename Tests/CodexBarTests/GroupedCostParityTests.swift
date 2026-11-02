import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct GroupedCostParityTests {
    @Test func `recorded OMP assistant and side calls match installed CodeBurn by model and day`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "grouped-cost-codeburn", withExtension: "json", subdirectory: "Fixtures/CostUsage"))
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let entries = try #require(fixture["entries"] as? [[String: Any]])
        let expected = try #require(fixture["codeburn"] as? [[String: Any]])
        _ = try env.writePiSessionFile(
            relativePath: "project/recorded.jsonl",
            contents: env.jsonl([["type": "session", "id": "recorded-session"]] + entries))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let since = try #require(ISO8601DateParser.parse("2026-10-26T00:00:00Z"))
        let now = try #require(ISO8601DateParser.parse("2026-11-01T21:23:20Z"))
        let options = PiSessionCostScanner.Options(
            ompSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            calendar: calendar,
            refreshMinIntervalSeconds: 3600)
        for provider in [UsageProvider.claude, .codex, .grok] {
            let result = try PiSessionCostScanner.loadDailyReportResultCancellable(
                provider: provider,
                since: since,
                until: now,
                now: now,
                options: options,
                checkCancellation: nil)
            #expect(result.isComplete)
            for day in result.report.data {
                for model in day.modelBreakdowns ?? [] {
                    let rows = expected.filter {
                        $0["model"] as? String == model.modelName &&
                            ($0["timestamp"] as? String)?.hasPrefix(day.date) == true
                    }
                    let usd = rows.reduce(0) { $0 + ($1["costUSD"] as? Double ?? 0) }
                    #expect(!rows.isEmpty)
                    #expect(abs((model.costUSD ?? -1) - usd) < 1e-8)
                    #expect(model.requestCount == rows.count)
                }
            }
            let expectedCount = expected.filter {
                let model = $0["model"] as? String ?? ""
                switch provider {
                case .claude: return model.hasPrefix("claude-")
                case .codex: return model.hasPrefix("gpt-")
                default: return model.hasPrefix("grok-")
                }
            }.count
            #expect(result.report.data.reduce(0) { $0 + ($1.requestCount ?? 0) } == expectedCount)
        }
    }

    @Test func `Grok native logs add to mirrors and mirror changes invalidate the cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 11, day: 1)
        let timestamp = env.isoString(for: now)
        let logURL = env.root.appendingPathComponent("logs/unified.jsonl")
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try """
        {"msg":"model changed","sid":"native","ctx":{"model":"grok-4.7"}}
        {"msg":"shell.turn.inference_done","sid":"native","ts":"\(timestamp)",\
        "ctx":{"prompt_tokens":100000,"cached_prompt_tokens":50000,"completion_tokens":10000}}
        """.write(to: logURL, atomically: true, encoding: .utf8)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: now)
        func mirrors(_ usd: Double, unknown: String? = nil) -> CostUsageDailyReport {
            CostUsageDailyReport(data: [.init(
                date: dayKey,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: usd,
                modelsUsed: nil,
                modelBreakdowns: unknown.map { [.init(modelName: $0, costUSD: nil)] })], summary: nil)
        }
        let first = try GrokDailyCostCache.scan(
            home: env.root,
            now: now,
            calendar: .current,
            previousSignature: nil,
            mirrors: mirrors(1))
        #expect(abs((first.cost?.usd ?? 0) - 1.185) < 1e-8)
        #expect(first.cost?.estimated == false)
        let unchanged = try GrokDailyCostCache.scan(
            home: env.root,
            now: now,
            calendar: .current,
            previousSignature: first.signature,
            mirrors: mirrors(1))
        #expect(unchanged.cost == nil)
        let changed = try GrokDailyCostCache.scan(
            home: env.root,
            now: now,
            calendar: .current,
            previousSignature: first.signature,
            mirrors: mirrors(2))
        #expect(abs((changed.cost?.usd ?? 0) - 2.185) < 1e-8)
        #expect(changed.cost?.estimated == false)
        let summary = GroupedDailyCost.summary(inputs: [.init(name: "Grok", value: .exact(2.185))])
        #expect(!summary.lines.joined().contains("≈"))
        let unpriced = try GrokDailyCostCache.scan(
            home: env.root,
            now: now,
            calendar: .current,
            previousSignature: nil,
            mirrors: mirrors(0, unknown: "grok-unknown-a"))
        #expect(unpriced.cost?.unpricedModels == ["grok-unknown-a"])
        #expect(unpriced.cost?.estimated == false)
        let renamed = try GrokDailyCostCache.scan(
            home: env.root,
            now: now,
            calendar: .current,
            previousSignature: unpriced.signature,
            mirrors: mirrors(0, unknown: "grok-unknown-b"))
        #expect(renamed.cost?.unpricedModels == ["grok-unknown-b"])
    }

    @Test func `zero reported Grok cost uses official tiers and excludes empty assistant responses`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 11, day: 1)
        let timestamp = env.isoString(for: day)
        let usage: [String: Any] = [
            "input": 50000, "cacheRead": 250_000, "output": 10000,
            "reasoningTokens": 4000, "cost": ["total": 0],
        ]
        let entries: [[String: Any]] = [
            ["type": "session", "id": "zero-reported"],
            ["type": "message", "id": "request", "timestamp": timestamp, "message": [
                "role": "assistant", "provider": "xai-oauth", "model": "grok-4.7", "usage": usage,
            ]],
            ["type": "message", "id": "empty", "timestamp": timestamp, "message": [
                "role": "assistant", "provider": "xai-oauth", "model": "grok-4.7",
                "usage": ["input": 0, "output": 0, "cacheRead": 100],
            ]],
            [
                "type": "model_usage",
                "id": "side",
                "timestamp": timestamp,
                "provider": "xai-oauth",
                "model": "grok-4.7",
                "purpose": "cache-warm",
                "usage": ["input": 0, "output": 0, "cacheRead": 100],
            ],
        ]
        _ = try env.writePiSessionFile(relativePath: "zero-reported.jsonl", contents: env.jsonl(entries))
        let report = PiSessionCostScanner.loadDailyReport(
            provider: .grok,
            since: day,
            until: day,
            now: day,
            options: .init(ompSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot))
        #expect(abs((report.summary?.totalCostUSD ?? 0) - 0.57005) < 1e-8)
        #expect(report.data.first?.requestCount == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_GROUPED_COST_CORPUS"] != nil))
    func `explicit sanitized corpus emits model level parity evidence`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let path = try #require(ProcessInfo.processInfo.environment["CODEXBAR_GROUPED_COST_CORPUS"])
        let now = try #require(ISO8601DateParser.parse("2026-11-01T21:23:20.053Z"))
        let since = try #require(Calendar.current.date(byAdding: .day, value: -6, to: now))
        let options = PiSessionCostScanner.Options(
            ompSessionsRoot: URL(fileURLWithPath: path),
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        var evidence: [String: [[String: Any]]] = [:]
        for provider in [UsageProvider.claude, .codex, .grok] {
            let result = try PiSessionCostScanner.loadDailyReportResultCancellable(
                provider: provider,
                since: since,
                until: now,
                now: now,
                options: options,
                checkCancellation: nil)
            #expect(result.isComplete)
            evidence[provider.rawValue] = result.report.data.flatMap { day in
                (day.modelBreakdowns ?? []).map { model in
                    [
                        "day": day.date,
                        "model": model.modelName,
                        "usd": model.costUSD ?? -1,
                        "calls": model.requestCount ?? -1,
                    ] as [String: Any]
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        try print("GROUPED_COST_PARITY=" + #require(String(bytes: data, encoding: .utf8)))
    }
}
