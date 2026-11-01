import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionMemoryTests {
    @Test
    func `unchanged refreshes allocate no artifact buffers and append rewrites only one file`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
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
            files.append(try env.writePiSessionFile(
                relativePath: "project/2026-07-10T10-00-00-000Z_\(index).jsonl",
                contents: env.jsonl([
                    ["type": "session", "id": "session-\(index)"], row,
                ])))
        }
        let work = Work()
        try CostUsageClaudeFragments.$shared.withValue(CostUsageClaudeFragments()) {
            func scan(_ seconds: TimeInterval) throws -> PiSessionCostScanner.DailyReportResult {
                try PiSessionCostScanner.loadDailyReportResultCancellable(
                    provider: .codex, since: day, until: day, now: day.addingTimeInterval(seconds),
                    options: options, checkCancellation: nil)
            }
            let first = try scan(0)
            #expect(first.isComplete)
            #expect(first.report.summary?.totalTokens == 480)
            try PiSessionCostScanner.$sessionParseObserverForTesting.withValue({ work.parsed() }) {
                try CostUsageClaudeFragments.$observeEncodedBytesForTesting.withValue({ work.encoded($0) }) {
                    try CostUsageClaudeCacheIO.$readForTesting.withValue({ url, options in
                        work.read()
                        return try? Data(contentsOf: url, options: options)
                    }) {
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

    private final class Work: @unchecked Sendable {
        private let lock = NSLock()
        private var parses = 0
        private var encodes: [Int] = []
        private var reads = 0
        var counts: [Int] { self.lock.withLock { [self.parses, self.encodes.count, self.reads] } }
        var maximumEncodedBytes: Int { self.lock.withLock { self.encodes.max() ?? 0 } }

        func parsed() { self.lock.withLock { self.parses += 1 } }
        func encoded(_ bytes: Int) { self.lock.withLock { self.encodes.append(bytes) } }
        func read() { self.lock.withLock { self.reads += 1 } }
    }
}
