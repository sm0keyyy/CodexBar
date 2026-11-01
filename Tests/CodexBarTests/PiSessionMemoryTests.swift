import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionMemoryTests {
    @Test
    func `unchanged refreshes reuse file buffers and append rewrites only one file`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
        try FileManager.default.createDirectory(
            at: env.root.appendingPathComponent("empty-omp"), withIntermediateDirectories: true)
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            ompSessionsRoot: env.root.appendingPathComponent("empty-omp"),
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let row: [String: Any] = [
            "type": "message", "id": "first", "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant", "provider": "openai-codex", "model": "gpt-5.4",
                "usage": ["input": 10, "output": 5, "totalTokens": 15],
            ],
        ]
        var files: [URL] = []
        for index in 0..<32 {
            try files.append(env.writePiSessionFile(
                relativePath: "project/2026-07-10T10-00-00-000Z_\(index).jsonl",
                contents: env.jsonl([
                    ["type": "session", "id": "session-\(index)"], row, row,
                ])))
        }
        let work = Work()
        let parsed: @Sendable () -> Void = { work.parsed() }
        let encoded: @Sendable (Int) -> Void = { work.encoded($0) }
        let decoded: @Sendable () -> Void = { work.decoded() }
        let read: @Sendable (URL, Data.ReadingOptions) -> Data? = { url, options in
            work.read()
            return try? Data(contentsOf: url, options: options)
        }
        try PiSessionCostScanner.$entryArchiveDecodeObserverForTesting.withValue(decoded) {
            try CostUsageClaudeFragments.$shared.withValue(CostUsageClaudeFragments()) {
                func scan(_ seconds: TimeInterval) throws -> PiSessionCostScanner.DailyReportResult {
                    try PiSessionCostScanner.loadDailyReportResultCancellable(
                        provider: .codex,
                        since: day,
                        until: day,
                        now: day.addingTimeInterval(seconds),
                        options: options,
                        checkCancellation: nil)
                }
                let first = try scan(0)
                #expect(first.isComplete)
                #expect(first.report.summary?.totalTokens == 480)
                let artifact = PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
                let initialStamp = CostUsageClaudeFileStamp.read(at: artifact)
                try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(parsed) {
                    try CostUsageClaudeFragments.$observeEncodedBytesForTesting.withValue(encoded) {
                        try CostUsageClaudeCacheIO.$readForTesting.withValue(read) {
                            for seconds in 1...10 {
                                let unchanged = try scan(TimeInterval(seconds))
                                #expect(unchanged.isComplete)
                                #expect(unchanged.report.data == first.report.data)
                            }
                            #expect(work.counts == [0, 0, 0, 0])
                            #expect(CostUsageClaudeFileStamp.read(at: artifact) == initialStamp)
                            #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).lastScanUnixMs
                                == Int64(day.addingTimeInterval(10).timeIntervalSince1970 * 1000))
                            let handle = try FileHandle(forWritingTo: #require(files.first))
                            defer { try? handle.close() }
                            var appended = row
                            appended["id"] = "appended"
                            try handle.seekToEnd()
                            try handle.write(contentsOf: Data(env.jsonl([appended]).utf8))
                            let changed = try scan(11)
                            #expect(changed.isComplete)
                            #expect(changed.report.summary?.totalTokens == 495)
                            #expect(work.counts == [1, 1, 0, 1])
                            #expect(work.maximumEncodedBytes < 4096)
                            let refreshed = try scan(12)
                            #expect(refreshed.report.data == changed.report.data)
                            #expect(work.counts == [1, 1, 0, 1])
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [9, 10])
    func `cold cache reads never decode an older monolithic artifact`(version: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let current = PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        let previous = current.deletingLastPathComponent().appendingPathComponent("pi-sessions-v\(version).json")
        try FileManager.default.createDirectory(
            at: previous.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 1024 * 1024).write(to: previous)
        let reader: @Sendable (URL, Data.ReadingOptions) -> Data? = { url, options in
            #expect(url != previous)
            return try? Data(contentsOf: url, options: options)
        }
        let cache = CostUsageClaudeCacheIO.$readForTesting.withValue(reader) {
            PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        }
        #expect(cache.version == 11)
        #expect(cache.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: current.path))
        #expect(try FileManager.default.attributesOfItem(atPath: previous.path)[.size] as? Int == 1024 * 1024)
    }

    @Test
    func `wide and narrow reports preserve coverage without reparsing unchanged sessions`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
        let older = day.addingTimeInterval(-90 * 86400)
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0,
            environment: ["HOME": env.root.path])
        for (name, timestamp) in [("older", older), ("today", day)] {
            _ = try env.writePiSessionFile(relativePath: "\(name).jsonl", contents: env.jsonl([
                ["type": "session", "id": name],
                ["type": "message", "id": "first", "timestamp": env.isoString(for: timestamp), "message": [
                    "role": "assistant", "provider": "openai-codex", "model": "gpt-5.4",
                    "usage": ["input": 10, "output": 5, "totalTokens": 15],
                ]],
            ]))
        }
        func scan(_ since: Date) throws -> PiSessionCostScanner.DailyReportResult {
            try PiSessionCostScanner.loadDailyReportResultCancellable(
                provider: .codex,
                since: since,
                until: day,
                now: day,
                options: options,
                checkCancellation: nil)
        }
        let first = try scan(older)
        #expect(first.isComplete)
        #expect(first.report.summary?.totalTokens == 30)
        let observer: @Sendable () -> Void = { Issue.record("Retained scan coverage must not cause a reparse") }
        try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            let narrow = try scan(day)
            let wide = try scan(older)
            #expect(narrow.report.summary?.totalTokens == 15)
            #expect(wide.report.data == first.report.data)
        }
    }

    @Test
    func `compact entry archives preserve counters and reject damaged payloads`() throws {
        let entry = PiSessionEntryUsage(
            providerRawValue: "codex",
            dayKey: "2026-07-10",
            modelName: "gpt-5.4",
            usage: PiPackedUsage(
                inputTokens: 100,
                totalTokens: 100,
                costNanos: 10,
                costSampleCount: 1,
                usageSampleCount: 1))
        var entries = Dictionary(uniqueKeysWithValues: (0..<4096).map { (String(format: "%016x", $0), entry) })
        entries["zero"] = PiSessionEntryUsage(
            providerRawValue: "codex", dayKey: "2026-07-10", modelName: "gpt-5.4", usage: PiPackedUsage())
        let archive = try PiSessionEntryUsageArchive(entries: entries)
        #expect(archive.bytes.count < 512 * 1024)
        #expect(try archive.decode() == entries)
        let reversed = Dictionary(uniqueKeysWithValues: entries.sorted { $0.key > $1.key })
        #expect(try PiSessionEntryUsageArchive(entries: reversed).bytes == archive.bytes)
        let data = try JSONEncoder().encode(archive)
        let restored = try JSONDecoder().decode(PiSessionEntryUsageArchive.self, from: data)
        #expect(try restored.decode() == entries)
        #expect(restored.contributions["codex"]?["2026-07-10"]?["gpt-5.4"]?.totalTokens == 409_600)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["bytes"] = Data("invalid binary plist".utf8).base64EncodedString()
        let damaged = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PiSessionEntryUsageArchive.self, from: damaged)
        }
        object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["contributions"] = [String: String]()
        let mismatched = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PiSessionEntryUsageArchive.self, from: mismatched)
        }
    }

    private final class Work: @unchecked Sendable {
        private let lock = NSLock()
        private var parses = 0
        private var encodes: [Int] = []
        private var reads = 0
        private var archiveDecodes = 0
        var counts: [Int] {
            self.lock.withLock { [self.parses, self.encodes.count, self.reads, self.archiveDecodes] }
        }

        var maximumEncodedBytes: Int {
            self.lock.withLock { self.encodes.max() ?? 0 }
        }

        func parsed() { self.lock.withLock { self.parses += 1 } }
        func encoded(_ bytes: Int) { self.lock.withLock { self.encodes.append(bytes) } }
        func read() { self.lock.withLock { self.reads += 1 } }
        func decoded() { self.lock.withLock { self.archiveDecodes += 1 } }
    }
}
