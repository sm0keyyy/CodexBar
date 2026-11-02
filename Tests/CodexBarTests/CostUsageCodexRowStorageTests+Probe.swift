import CryptoKit
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import CodexBarCore

extension CostUsageCodexRowStorageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_CODEX_ROW_PROBE"] != nil))
    func `explicit row scan probe records footprint and corpus parity`() throws {
        let environment = ProcessInfo.processInfo.environment
        let output = try URL(fileURLWithPath: #require(environment["CODEXBAR_CODEX_ROW_PROBE"]))
        var evidence: [String: RowProbeEvidence] = [:]
        if environment["CODEXBAR_CODEX_ROW_CORPUS_ONLY"] != "1" {
            let env = try CostUsageTestEnvironment()
            defer { env.cleanup() }
            let day = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
            let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
            let count = 40000
            let line = """
            {"type":"event_msg","timestamp":"2026-08-01T12:00:00Z","payload":{"type":"token_count",\
            "info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}}}
            """
            let file = try env.writeCodexSessionFile(
                day: day, filename: "rows.jsonl", contents: String(repeating: line + "\n", count: count))
            let before = Self.rowProbeFootprint()
            let parsed = try CostUsageScanner.parseCodexFileCancellable(
                fileURL: file,
                range: range,
                initialModel: "gpt-5.4")
            let after = Self.rowProbeFootprint()
            #expect(parsed.rows.count == count)
            print("[codex-row-footprint] before=\(before) after=\(after) delta=\(Int64(after) - Int64(before)) "
                + "rows=\(parsed.rows.count) stride=\(MemoryLayout<CostUsageScanner.CodexUsageRow>.stride)")
            evidence["fixture"] = try Self.rowProbeTotals(files: [file], range: range, initialModel: "gpt-5.4")
            withExtendedLifetime(parsed) {}
        }
        if let root = environment["CODEXBAR_CODEX_ROW_CORPUS"] {
            let enumerator = try #require(FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))
            let files = try enumerator.compactMap { value -> URL? in
                guard let url = value as? URL, url.pathExtension == "jsonl",
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
                return url
            }.sorted { $0.path < $1.path }
            #expect(!files.isEmpty)
            let since = try #require(ISO8601DateParser.parse("2000-01-01T00:00:00Z"))
            let until = try #require(ISO8601DateParser.parse("2100-01-01T00:00:00Z"))
            evidence["live"] = try Self.rowProbeTotals(
                files: files, range: .init(since: since, until: until), initialModel: nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(evidence).write(to: output)
    }

    private struct RowProbeEvidence: Codable {
        var files: Int
        var rows: Int
        var sourceDigest: String
        var rowDigest: String
        var totals: [String: [Int64]]
    }

    private static func rowProbeTotals(
        files: [URL], range: CostUsageScanner.CostUsageDayRange, initialModel: String?) throws -> RowProbeEvidence
    {
        var sourceHash = SHA256()
        var rowHash = SHA256()
        var totals: [String: [Int64]] = [:]
        var rowCount = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let catalog = ModelsDevCatalog(providers: [:])
        for file in files {
            let source = try Data(contentsOf: file)
            sourceHash.update(data: source)
            let parsed = try CostUsageScanner.parseCodexFileCancellable(
                fileURL: file, range: range, initialModel: initialModel)
            #expect(parsed.parsedBytes == source.count)
            try rowHash.update(data: encoder.encode(parsed.rows))
            rowCount += parsed.rows.count
            for row in parsed.rows {
                let key = "codex/\(row.day)/\(row.model)"
                var value = totals[key] ?? [0, 0, 0, 0, 0, 0]
                value[0] += Int64(row.input)
                value[1] += Int64(row.cached)
                value[2] += Int64(row.output)
                value[3] += Int64(row.reasoning ?? 0)
                if let cost = CostUsageScanner.codexResolvedCostNanos(
                    for: row, modelsDevCatalog: catalog, modelsDevCacheRoot: nil)
                {
                    value[4] += cost
                } else {
                    value[5] += 1
                }
                totals[key] = value
            }
        }
        print("[codex-row-parity] files=\(files.count) rows=\(rowCount) groups=\(totals.count)")
        return RowProbeEvidence(
            files: files.count,
            rows: rowCount,
            sourceDigest: sourceHash.finalize().map { String(format: "%02x", $0) }.joined(),
            rowDigest: rowHash.finalize().map { String(format: "%02x", $0) }.joined(),
            totals: totals)
    }

    private static func rowProbeFootprint() -> UInt64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
        #else
        return 0
        #endif
    }
}
