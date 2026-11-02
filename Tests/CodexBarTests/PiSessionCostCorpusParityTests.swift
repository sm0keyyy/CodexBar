import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostCorpusParityTests {
    @Test
    func `read only live corpus report parity`() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["CODEXBAR_PI_PARITY_ROOT"],
              let output = environment["CODEXBAR_PI_PARITY_OUTPUT"] else { return }
        let corpus = URL(fileURLWithPath: root, isDirectory: true)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_793_577_600) // 2026-11-02 UTC.
        let since = Date(timeIntervalSince1970: 1_790_812_800) // 2026-10-01 UTC.
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: corpus.appendingPathComponent("pi"),
            ompSessionsRoot: corpus.appendingPathComponent("omp"),
            cacheRoot: env.cacheRoot,
            calendar: calendar,
            refreshMinIntervalSeconds: 3600,
            environment: [:])
        let sampler = Process()
        if let sample = environment["CODEXBAR_PI_PARITY_SAMPLE"] {
            sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sampler.arguments = [String(ProcessInfo.processInfo.processIdentifier), "5", "1", "-file", sample]
            sampler.standardOutput = FileHandle.nullDevice
            sampler.standardError = FileHandle.nullDevice
            try sampler.run()
        }
        var reports: [String: CostUsageDailyReport] = [:]
        for provider in [UsageProvider.grok, .codex, .claude, .pi] {
            reports[provider.rawValue] = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: provider, since: since, until: now, now: now, options: options, checkCancellation: nil)
        }
        if sampler.isRunning { sampler.waitUntilExit() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(reports)
        if let baseline = environment["CODEXBAR_PI_PARITY_BASELINE"] {
            #expect(try data == Data(contentsOf: URL(fileURLWithPath: baseline)))
        }
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        let sevenDays = reports[UsageProvider.grok.rawValue]?.data.filter { $0.date >= "2026-10-27" }
        let total = sevenDays?.reduce(0.0) { $0 + ($1.costUSD ?? 0) } ?? 0
        print("Pi corpus parity: providers=\(reports.count), Grok seven-day USD=\(total)")
    }
}
