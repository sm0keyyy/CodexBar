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
                    ["type": "session", "id": "session-\(index)"], row,
                ])))
        }
        let work = Work()
        let parsed: @Sendable () -> Void = { work.parsed() }
        let encoded: @Sendable (Int) -> Void = { work.encoded($0) }
        let read: @Sendable (URL, Data.ReadingOptions) -> Data? = { url, options in
            work.read()
            return try? Data(contentsOf: url, options: options)
        }
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
            try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(parsed) {
                try CostUsageClaudeFragments.$observeEncodedBytesForTesting.withValue(encoded) {
                    try CostUsageClaudeCacheIO.$readForTesting.withValue(read) {
                        for seconds in 1...10 {
                            let unchanged = try scan(TimeInterval(seconds))
                            #expect(unchanged.isComplete)
                            #expect(unchanged.report.data == first.report.data)
                        }
                        #expect(work.counts == [0, 0, 0])
                        let handle = try FileHandle(forWritingTo: #require(files.first))
                        defer { try? handle.close() }
                        var appended = row
                        appended["id"] = "appended"
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data(env.jsonl([appended]).utf8))
                        let changed = try scan(11)
                        #expect(changed.isComplete)
                        #expect(changed.report.summary?.totalTokens == 495)
                        #expect(work.counts == [1, 1, 0])
                        #expect(work.maximumEncodedBytes < 4096)
                        let refreshed = try scan(12)
                        #expect(refreshed.report.data == changed.report.data)
                        #expect(work.counts == [1, 1, 0])
                    }
                }
            }
        }
    }

    @Test
    func `cold cache reads never decode an older monolithic artifact`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let current = PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        let previous = current.deletingLastPathComponent().appendingPathComponent("pi-sessions-v9.json")
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
        #expect(cache.version == 10)
        #expect(cache.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: current.path))
        #expect(try FileManager.default.attributesOfItem(atPath: previous.path)[.size] as? Int == 1024 * 1024)
    }

    private final class Work: @unchecked Sendable {
        private let lock = NSLock()
        private var parses = 0
        private var encodes: [Int] = []
        private var reads = 0
        var counts: [Int] {
            self.lock.withLock { [self.parses, self.encodes.count, self.reads] }
        }

        var maximumEncodedBytes: Int {
            self.lock.withLock { self.encodes.max() ?? 0 }
        }

        func parsed() { self.lock.withLock { self.parses += 1 } }
        func encoded(_ bytes: Int) { self.lock.withLock { self.encodes.append(bytes) } }
        func read() { self.lock.withLock { self.reads += 1 } }
    }
}
