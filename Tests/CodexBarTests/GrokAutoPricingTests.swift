import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct GrokAutoPricingTests {
    private func catalog(_ models: String) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {"xai":{"id":"xai","models":{\(models)}}}
        """.utf8))
    }

    @Test func `new and renamed Grok models price from the shared catalog cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let catalog = try self.catalog("""
        "grok-test-new":{"id":"grok-test-new","cost":{"input":3,"output":9,"cache_read":0.75}},
        "grok-build-latest":{"id":"grok-build-latest","cost":{"input":5,"output":10,"cache_read":1}}
        """)
        #expect(ModelsDevCache.save(catalog: catalog, cacheRoot: env.cacheRoot))
        let pricing = CostUsagePricing.GrokResolver(cacheRoot: env.cacheRoot)
        let tokens = CostUsagePricing.GrokTokens(fresh: 1000, output: 100, cacheRead: 2000, cacheCreation: 500)
        #expect(pricing.cost(model: "xai/grok-test-new", tokens: tokens) == 0.0069)
        #expect(pricing.cost(model: "grok-build-latest", tokens: tokens) == 0.0105)
        #expect(GroupedCostPriceTable.rates(model: "grok-test-new") == nil)
        let now = try #require(ISO8601DateParser.parse("2026-11-01T21:23:20Z"))
        let log = """
        {"msg":"model changed","sid":"s","ctx":{"model":"grok-test-new"}}
        {"msg":"shell.turn.inference_done","sid":"s","ts":"2026-11-01T18:00:00Z",\
        "ctx":{"prompt_tokens":3500,"cached_prompt_tokens":2000,"completion_tokens":100}}
        """
        let cost = GrokSessionCost.today(
            unifiedLog: log, sessions: [], now: now, calendar: Calendar(identifier: .gregorian), pricing: pricing)
        #expect(cost.usd == 0.0069)
        #expect(cost.unpricedModels.isEmpty)
    }

    @Test func `official tier fills missing catalog context rates at the inclusive threshold`() throws {
        let catalog = try self.catalog("""
        "grok-4.7":{"id":"grok-4.7","cost":{"input":2,"output":6,"cache_read":0.5}}
        """)
        let pricing = CostUsagePricing.GrokResolver(catalog: catalog)
        #expect(pricing.cost(
            model: "grok-4.7",
            tokens: .init(fresh: 50000, output: 10000, cacheRead: 100_000, cacheCreation: 50000)) == 0.62)
        #expect(pricing.rates(model: "grok-4.7", promptTokens: 199_999)?.input == 2)
        #expect(pricing.rates(model: "grok-4.7", promptTokens: 200_000)?.input == 4)
    }

    @Test func `new model context tiers from models dev remain authoritative`() throws {
        let catalog = try self.catalog("""
        "grok-test-new":{"id":"grok-test-new","cost":{"input":3,"output":9,"cache_read":0.75,\
        "context_over_200k":{"input":6,"output":18,"cache_read":1.5}}}
        """)
        let pricing = CostUsagePricing.GrokResolver(catalog: catalog)
        #expect(pricing.cost(
            model: "grok-test-new",
            tokens: .init(fresh: 100_000, output: 10000, cacheRead: 100_000, cacheCreation: 0)) == 0.93)
    }

    @Test func `offline cache uses bundled rates and unknown models retain their names`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let pricing = CostUsagePricing.GrokResolver(cacheRoot: env.cacheRoot)
        #expect(pricing.cost(
            model: "grok-4.7",
            tokens: .init(fresh: 50000, output: 10000, cacheRead: 250_000, cacheCreation: 0)) == 0.57)
        #expect(pricing.cost(
            model: "grok-test-unknown",
            tokens: .init(fresh: 50000, output: 10000, cacheRead: 250_000, cacheCreation: 0)) == nil)
        let now = try #require(ISO8601DateParser.parse("2026-11-01T21:23:20Z"))
        let log = """
        {"msg":"model changed","sid":"s","ctx":{"model":"grok-test-unknown"}}
        {"msg":"shell.turn.inference_done","sid":"s","ts":"2026-11-01T18:00:00Z",\
        "ctx":{"prompt_tokens":100,"completion_tokens":10}}
        """
        let cost = GrokSessionCost.today(
            unifiedLog: log, sessions: [], now: now, calendar: Calendar(identifier: .gregorian), pricing: pricing)
        #expect(cost.unpricedModels == ["grok-test-unknown"])
        #expect(cost.requestCount == 1)
    }

    @Test func `catalog updates invalidate mirrored Grok prices without touching session logs`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 11, day: 1)
        let timestamp = env.isoString(for: now)
        _ = try env.writePiSessionFile(relativePath: "new.jsonl", contents: """
        {"type":"session","id":"new"}
        {"type":"message","id":"request","timestamp":"\(timestamp)","message":{\
        "role":"assistant","provider":"xai","model":"grok-test-new",\
        "usage":{"input":1000,"output":100,"cacheRead":2000,"cacheWrite":500,"cost":{"total":0}}}}
        """)
        let options = PiSessionCostScanner.Options(ompSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot)
        let before = PiSessionCostScanner.loadDailyReport(
            provider: .grok, since: now, until: now, now: now, options: options)
        #expect(before.data.first?.modelBreakdowns?.first?.costUSD == nil)
        let catalog = try self.catalog("""
        "grok-test-new":{"id":"grok-test-new","cost":{"input":3,"output":9,"cache_read":0.75}}
        """)
        #expect(ModelsDevCache.save(catalog: catalog, cacheRoot: env.cacheRoot))
        let after = PiSessionCostScanner.loadDailyReport(
            provider: .grok, since: now, until: now, now: now, options: options)
        #expect(after.summary?.totalCostUSD == 0.0069)
        #expect(after.data.first?.modelBreakdowns?.first?.costUSD == 0.0069)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_GROK_PRICING_CORPUS"] != nil))
    func `live corpus preserves every provider day and model at one fixed cutoff`() throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try URL(fileURLWithPath: #require(environment["CODEXBAR_GROK_PRICING_CORPUS"]))
        let catalogURL = try URL(fileURLWithPath: #require(environment["CODEXBAR_GROK_PRICING_CATALOG"]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let artifact = try decoder.decode(ModelsDevCacheArtifact.self, from: Data(contentsOf: catalogURL))
        let old = try CostUsageTestEnvironment()
        defer { old.cleanup() }
        let new = try CostUsageTestEnvironment()
        defer { new.cleanup() }
        var oldCatalog = artifact.catalog
        oldCatalog.providers.removeValue(forKey: "xai")
        #expect(ModelsDevCache.save(catalog: oldCatalog, cacheRoot: old.cacheRoot))
        #expect(ModelsDevCache.save(catalog: artifact.catalog, cacheRoot: new.cacheRoot))
        let now = try #require(ISO8601DateParser.parse("2026-11-01T21:23:20.053Z"))
        let calendar = Calendar.current
        let since = try #require(calendar.date(byAdding: .day, value: -6, to: now))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var totals: [String: Double] = [:]
        for provider in [UsageProvider.grok, .claude, .codex] {
            func report(cacheRoot: URL) throws -> CostUsageDailyReport {
                let result = try PiSessionCostScanner.loadDailyReportResultCancellable(
                    provider: provider,
                    since: since,
                    until: now,
                    now: now,
                    options: .init(
                        piSessionsRoot: root.appendingPathComponent("pi"),
                        ompSessionsRoot: root.appendingPathComponent("omp"),
                        cacheRoot: cacheRoot,
                        calendar: calendar,
                        environment: [:]),
                    checkCancellation: nil)
                #expect(result.isComplete)
                return result.report
            }
            let before = try report(cacheRoot: old.cacheRoot)
            let after = try report(cacheRoot: new.cacheRoot)
            #expect(try encoder.encode(before) == encoder.encode(after))
            totals[provider.rawValue] = after.summary?.totalCostUSD ?? 0
            if provider == .grok {
                let today = CostUsageTokenSnapshot.entry(
                    in: after.data, forLocalDayContaining: now, calendar: calendar)?.costUSD ?? 0
                print("GROK_PRICING_PARITY today=\(today) sevenDay=\(totals[provider.rawValue] ?? 0)")
            }
        }
        print("GROK_PRICING_PROVIDER_TOTALS \(totals)")
    }
}
