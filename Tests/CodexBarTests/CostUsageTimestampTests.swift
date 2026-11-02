import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTimestampTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_PARSE_CORPUS_CLAUDE_ROOT"] != nil))
    func `explicit native corpus emits exact reports and single scan timing`() throws {
        let environment = ProcessInfo.processInfo.environment
        let claudeRoot = try #require(environment["CODEXBAR_PARSE_CORPUS_CLAUDE_ROOT"])
        let output = try #require(environment["CODEXBAR_PARSE_CORPUS_OUTPUT"])
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let since = try #require(Self.historicalDate("1900-01-01T00:00:00Z"))
        let until = try #require(Self.historicalDate("2026-11-02T00:00:00Z"))
        let codexRoot = environment["CODEXBAR_PARSE_CORPUS_CODEX_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? env.codexSessionsRoot
        let options = CostUsageScanner.Options(
            codexSessionsRoot: codexRoot,
            claudeProjectsRoots: [URL(fileURLWithPath: claudeRoot)],
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("absent.sqlite"),
            calendar: calendar,
            maxCodexSessionFileBytes: .max,
            maxCodexScanBytesPerRefresh: .max)
        var reports: [String: CostUsageDailyReport] = [:]
        let start = ProcessInfo.processInfo.systemUptime
        let cpuStart = clock()
        for provider in [UsageProvider.claude, .codex] {
            reports[provider.rawValue] = try CostUsageScanner.loadDailyReportCancellable(
                provider: provider,
                since: since,
                until: until,
                now: until,
                options: options,
                checkCancellation: nil)
        }
        let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(reports).write(to: URL(fileURLWithPath: output))
        #expect(reports["claude"]?.data.isEmpty == false)
        print("PARSE_CORPUS elapsed=\(elapsed) cpu=\(cpu) output=\(output)")
    }

    @Test
    func `generated native epochs equal the former formatter path`() throws {
        var seed: UInt64 = 0x52_4643_3333_3339
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int(seed >> 32) % bound
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let formatter = Date.ISO8601FormatStyle()
        let zones = [
            "Z", "+00:00", "-00:00", "+05:30", "-08:00", "+14:00", "-12:45",
            "+18:00", "-18:00", "+18:01", "-18:01", "+23:59", "-23:59",
        ]
        for index in 0..<10000 {
            let year = 1900 + next(8100)
            let month = 1 + next(12)
            let first = try #require(calendar.date(from: DateComponents(year: year, month: month, day: 1)))
            let days = try #require(calendar.range(of: .day, in: .month, for: first))
            let day = index.isMultiple(of: 2) ? days.count : 1 + next(days.count)
            let whole = String(
                format: "%04d-%02d-%02dT%02d:%02d:%02d",
                year,
                month,
                day,
                next(24),
                next(60),
                next(60))
            let width = index % 10
            let digits = String(String(format: "%09d", next(1_000_000_000)).prefix(width))
            let fraction = width == 0 ? "" : "." + digits
            let milliseconds = try #require(Int((digits + "000").prefix(3)))
            let zone = zones[next(zones.count)]
            let text = whole + fraction + zone
            let expected: Date? = if let oldWhole = try? formatter.parse(whole + zone) {
                Date(
                    timeIntervalSince1970: oldWhole.timeIntervalSince1970 + Double(milliseconds) / 1000)
            } else {
                Self.historicalDate(text)
            }
            #expect(CostUsageScanner.dateFromTimestamp(text) == expected, "\(text)")
        }
    }

    private static func historicalDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    @Test
    func `native timestamps preserve exact formatter precision`() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        for year in [1900, 1960, 1969, 1970, 2000, 2024, 2026, 2100, 2400, 9999] {
            for day in ["01-01", "02-28", "03-01", "12-31"] {
                for time in ["00:00:00", "12:34:56", "23:59:59"] {
                    for fraction in ["", ".0", ".1", ".01", ".123", ".999", ".123456", ".999999999"] {
                        for zone in ["Z", "+00:00", "-00:00", "+05:30", "-08:00"] {
                            let text = "\(year)-\(day)T\(time)\(fraction)\(zone)"
                            let expected = fractional.date(from: text) ?? plain.date(from: text)
                            #expect(CostUsageScanner.dateFromTimestamp(text) == expected, "\(text)")
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [
        "2024-02-29T23:59:59.999Z", "2000-02-29T12:00:00Z",
        "2026-08-30T12:34:56+0530", "2026-08-30T12:34:56+05",
        "2026-08-30T12:34:56.123456789012Z", "2026-08-30T12:34:56.1234567890Z",
        "1582-10-04T12:34:56Z", "0001-01-01T00:00:00Z",
        "2026-08-30T12:34:56+23:59", "2026-08-30T12:34:56Ztrailing",
        "2026-02-30T12:34:56Z", "1900-02-29T12:00:00Z",
        "2026-08-30T24:00:00Z", "2016-12-31T23:59:60Z",
        "", "2026-08-30", "not-a-date", "2026-08-30t12:34:56z",
        "2026-13-01T00:00:00Z", "2026-08-30T12:34:56.Z",
        "2026-08-30T12:34:56.123", "2026-08-30T12:34:56+25:00",
        "2026-08-30T12:34:56+05:99", "2026-08-30T12:34:56.١Z",
    ])
    func `historical spellings and invalid inputs retain formatter behavior`(_ text: String) {
        #expect(CostUsageScanner.dateFromTimestamp(text) == Self.historicalDate(text))
    }

    @Test(arguments: ["America/Los_Angeles", "Asia/Kolkata", "Pacific/Kiritimati", "UTC"])
    func `Claude reuses parsed date without changing local days`(_ timeZone: String) throws {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = try #require(TimeZone(identifier: timeZone))
        for text in [
            "2026-03-08T09:59:59.999999Z", "2026-03-08T10:00:00.000Z",
            "2026-11-01T08:59:59.999999Z", "2026-11-01T09:00:00Z",
            "2026-08-30T23:59:59.999999999-08:00", "2024-02-29T23:59:59.999+05:30",
            "1969-12-31T23:59:59.999999Z", "2026-08-30T12:34:56+0530",
            "2026-02-30T12:00:00Z", "2016-12-31T23:59:60Z",
        ] {
            guard let expectedDate = Self.historicalDate(text) else {
                #expect(CostUsageScanner.claudeTimestampAndDayKey(text, calendar: calendar) == nil)
                continue
            }
            let expectedDay = CostUsageScanner.dayKeyFromTimestamp(text, calendar: calendar)
                ?? CostUsageScanner.CostUsageDayRange.dayKey(from: expectedDate, calendar: calendar)
            let actual = try #require(CostUsageScanner.claudeTimestampAndDayKey(text, calendar: calendar))
            #expect(actual.date == expectedDate)
            #expect(actual.dayKey == expectedDay)
        }
    }

    @Test
    func `Claude ingestion preserves tokens days deduplication and dated pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let timestamps = [
            "2026-03-08T09:59:59.999999Z", "2026-03-08T10:00:00Z",
            "2026-03-12T23:59:59.999999Z", "2026-03-13T00:00:00.000Z",
            "2026-03-13T00:00:00+0530", "2026-03-13T23:59:59.999-08:00",
        ]
        let model = "claude-sonnet-4-6"
        let lines = timestamps.enumerated().map { index, timestamp in
            [
                "type": "assistant", "timestamp": timestamp, "requestId": "request-\(index)",
                "message": [
                    "id": "message-\(index)", "model": model,
                    "usage": [
                        "input_tokens": 210_000, "output_tokens": 20,
                        "cache_creation_input_tokens": 50, "cache_read_input_tokens": 25,
                    ],
                ],
            ] as [String: Any]
        }
        let contents = try env.jsonl(lines + lines)
        let file = try env.writeClaudeProjectFile(
            relativePath: "synthetic/session.jsonl", contents: contents)
        let range = try CostUsageScanner.CostUsageDayRange(
            since: #require(Self.historicalDate("2026-03-01T00:00:00Z")),
            until: #require(Self.historicalDate("2026-03-31T00:00:00Z")),
            calendar: calendar)
        let parsed = try CostUsageScanner.parseClaudeFileCancellable(
            fileURL: file,
            range: range,
            providerFilter: .all,
            pricingResolver: CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: env.cacheRoot))
        #expect(parsed.rows.count == timestamps.count)
        var expectedDays: [String: [String: [Int]]] = [:]
        for (index, text) in timestamps.enumerated() {
            let date = try #require(Self.historicalDate(text))
            let day = try #require(CostUsageScanner.dayKeyFromTimestamp(text, calendar: calendar))
            let cost = try #require(CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: 210_000,
                cacheReadInputTokens: 25,
                cacheCreationInputTokens: 50,
                outputTokens: 20,
                pricingDate: date,
                modelsDevCacheRoot: env.cacheRoot))
            let nanos = Int((cost * 1_000_000_000).rounded())
            let row = try #require(parsed.rows.first { $0.messageId == "message-\(index)" })
            #expect(row.timestampUnixMs == Int64((date.timeIntervalSince1970 * 1000).rounded()))
            #expect(row.dayKey == day)
            #expect(row.costNanos == nanos)
            let packed = [210_000, 25, 50, 20, nanos, 1, 1, 0]
            var total = expectedDays[day]?[model] ?? Array(repeating: 0, count: packed.count)
            for slot in packed.indices {
                total[slot] += packed[slot]
            }
            expectedDays[day] = [model: total]
        }
        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot, calendar: calendar)
        let since = try #require(Self.historicalDate("2026-03-01T00:00:00Z"))
        let until = try #require(Self.historicalDate("2026-03-31T00:00:00Z"))
        let report = CostUsageScanner.loadDailyReport(
            provider: .claude, since: since, until: until, now: until, options: options)
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot).usage
        #expect(cache.days == expectedDays)
        #expect(cache.files.values.flatMap { $0.claudeRows ?? [] } == parsed.rows)
        #expect(report.data.count == expectedDays.count)
        #expect(report.summary?.totalTokens == timestamps.count * (210_000 + 25 + 50 + 20))
        #expect(parsed.parsedBytes == Int64(Data(contents.utf8).count))
    }
}
