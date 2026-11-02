import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexRowStorageTests {
    enum ReadMode: CaseIterable {
        case report, scan, cache, snapshot
    }

    @Test(arguments: ReadMode.allCases)
    func `retained Codex rows share identical turn strings without changing their bytes`(mode: ReadMode) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 1)
        defer { fixture.remove() }
        let turns: [String?] = [
            nil,
            "synthetic-turn-caf\u{e9}-00000001",
            "synthetic-turn-cafe\u{301}-00000001",
            "synthetic-turn-third-0000000001",
        ]
        let rows = (0..<10000).map { index in
            CostUsageScanner.CodexUsageRow(
                day: ReadWorkFixture.day,
                model: ReadWorkFixture.model,
                rawModel: "synthetic-original-model",
                turnID: turns[index % turns.count],
                eventIndex: index,
                timestampUnixMs: 1_785_542_400_000 + Int64(index),
                input: index,
                cached: 2,
                output: 3,
                reasoning: 1,
                knownCostNanos: Int64(index),
                pricingModel: "synthetic-priced-model",
                pricingMode: index.isMultiple(of: 2) ? "priority" : nil,
                responseID: "synthetic-response-\(index)",
                requestMirrorKeys: ["synthetic-mirror-\(index)"])
        }
        var cache = fixture.canonical
        let paths = cache.files.keys.sorted()
        cache.files[paths[0]]?.codexRows = Array(rows.prefix(5000))
        cache.files[paths[1]]?.codexRows = Array(rows.suffix(5000))
        #expect(!fixture.save(cache).catchUpRequired)
        let loaded: CostUsageCache
        switch mode {
        case .report:
            let view = fixture.store.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .report)
            loaded = try #require(Mirror(reflecting: view).children.first { $0.label == "cache" }?.value
                as? CostUsageCache)
        case .scan:
            let scan = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            loaded = scan.cache
            scan.release()
        case .cache:
            loaded = fixture.store.syncLoadCodexCache(calendar: fixture.calendar, loadTokenSnapshots: false)
        case .snapshot:
            loaded = await CostUsageStore.decodeCodexCache(from: fixture.store.readSnapshot(), recorder: nil)
        }
        let actual = paths.flatMap { loaded.files[$0]?.codexRows ?? [] }
        #expect(actual.count == rows.count)
        let strings = actual.compactMap(\.turnID)
        let identities = try Set(strings.map { value in
            try #require(value.utf8.withContiguousStorageIfAvailable { UInt(bitPattern: $0.baseAddress) })
        })
        print("[codex-row-storage] mode=\(mode) rows=\(actual.count) turnAllocations=\(identities.count)")
        #expect(identities.count == turns.compactMap(\.self).count)
        #expect(Set(strings.map { Data($0.utf8) }) == Set(turns.compactMap(\.self).map { Data($0.utf8) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(actual) == encoder.encode(rows))
    }

    @Test
    func `coded labels preserve legacy bytes and per day model tariff totals`() throws {
        let decoder = JSONDecoder()
        decoder.userInfo[CodexUsageRowStringTable.key] = CodexUsageRowStringTable()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = Data("""
        [
          {"day":"2026-08-01","model":"gpt-5.4","input":100000,"cached":20000,"output":1000},
          {"day":"2026-08-01","model":"gpt-5.4","rawModel":"café","pricingModel":"gpt-5.4",
           "pricingMode":"priority","input":300000,"cached":10000,"output":5000,"reasoning":-1},
          {"day":"2026-08-02","model":"gpt-5.4","rawModel":"cafe\\u0301","pricingModel":"",
           "pricingMode":"","input":1,"cached":0,"output":2,"knownCostNanos":0},
          {"day":"2026-08-02","model":"gpt-5.4","rawModel":"","pricingModel":"gpt-5.4-mini",
           "pricingMode":"standard","input":1000,"cached":100,"output":200,"knownCostNanos":42},
          {"day":"2026-08-02","model":"synthetic-unknown-model","input":10,"cached":2,"output":3}
        ]
        """.utf8)
        let legacy = try decoder.decode([LegacyRow].self, from: payload)
        let rows = try decoder.decode([CostUsageScanner.CodexUsageRow].self, from: payload)
        #expect(try encoder.encode(rows) == encoder.encode(legacy))
        #expect(rows[1].reasoning == -1)
        #expect(rows[2].rawModel?.utf8.elementsEqual("cafe\u{301}".utf8) == true)
        #expect(rows[3].rawModel?.isEmpty == true)
        let catalog = ModelsDevCatalog(providers: [:])
        var expected: [String: [Double?]] = [:]
        var actual: [String: [Double?]] = [:]
        for (old, row) in zip(legacy, rows) {
            let key = "codex/\(old.day)/\(old.model)"
            expected[key, default: []].append(old.cost(catalog: catalog))
            actual[key, default: []].append(CostUsageScanner.codexResolvedCostUSD(
                for: row, modelsDevCatalog: catalog, modelsDevCacheRoot: nil))
        }
        #expect(actual == expected)
        for key in expected.keys {
            #expect(actual[key]?.compactMap(\.self).reduce(0, +) == expected[key]?.compactMap(\.self).reduce(0, +))
        }
        var copy = rows[0]
        copy.pricingModel = "gpt-5.4-mini"
        copy.pricingMode = "priority"
        #expect(rows[0].pricingModel == nil)
        #expect(rows[0].pricingMode == nil)
        #expect(copy.pricingModel == "gpt-5.4-mini")
        #expect(copy.pricingMode == "priority")
        #expect(try copy == decoder.decode(CostUsageScanner.CodexUsageRow.self, from: encoder.encode(copy)))
        copy.pricingModel = nil
        copy.pricingMode = nil
        #expect(copy == rows[0])
    }

    /// The pre-coding persisted representation, kept independent of the resident row implementation.
    private struct LegacyRow: Codable {
        let day: String
        let model: String
        let rawModel: String?
        let turnID: String?
        let eventIndex: Int?
        let timestampUnixMs: Int64?
        let input: Int
        let cached: Int
        let output: Int
        let reasoning: Int?
        let responseID: String?
        let requestMirrorKeys: [String]?
        let knownCostNanos: Int64?
        let unpricedTokens: Int?
        let pricingModel: String?
        let pricingMode: String?
        let isIncludedInPlan: Bool?

        func cost(catalog: ModelsDevCatalog) -> Double? {
            if let knownCostNanos { return Double(knownCostNanos) / 1_000_000_000 }
            let model = self.pricingModel ?? self.model
            let date = self.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            let standard = CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: self.input,
                cachedInputTokens: self.cached,
                outputTokens: self.output,
                pricingDate: date,
                modelsDevCatalog: catalog)
            guard self.pricingMode == "priority",
                  let priority = CostUsagePricing.codexPriorityCostUSD(
                      model: model,
                      inputTokens: self.input,
                      cachedInputTokens: self.cached,
                      outputTokens: self.output,
                      pricingDate: date,
                      modelsDevCatalog: catalog)
            else { return standard }
            return max(priority, standard ?? priority)
        }
    }
}
