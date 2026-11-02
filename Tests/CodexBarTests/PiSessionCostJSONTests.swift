import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostJSONTests {
    @Test
    func `fixture provider day model totals retain legacy recorded cents`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let url = try #require(Bundle.module.url(
            forResource: "grouped-cost-codeburn", withExtension: "json", subdirectory: "Fixtures/CostUsage"))
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(fixture["entries"] as? [[String: Any]])
        let legacy = try #require(fixture["codeburn"] as? [[String: Any]])
        _ = try env.writePiSessionFile(relativePath: "fixture.jsonl", contents: env.jsonl(entries))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let since = try #require(ISO8601DateParser.parse("2026-10-26T00:00:00Z"))
        let now = try #require(ISO8601DateParser.parse("2026-11-01T21:23:20Z"))
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot, calendar: calendar)
        for provider in [UsageProvider.claude, .codex, .grok] {
            let result = try PiSessionCostScanner.loadDailyReportResultCancellable(
                provider: provider, since: since, until: now, now: now, options: options, checkCancellation: nil)
            #expect(result.isComplete)
            #expect(!result.report.data.isEmpty)
            for day in result.report.data {
                for model in day.modelBreakdowns ?? [] {
                    let expected = legacy.filter {
                        $0["model"] as? String == model.modelName &&
                            ($0["timestamp"] as? String)?.hasPrefix(day.date) == true
                    }
                    #expect(!expected.isEmpty)
                    let usd = expected.reduce(0.0) { $0 + ($1["costUSD"] as? Double ?? 0) }
                    #expect(((model.costUSD ?? -1) * 100).rounded() == (usd * 100).rounded())
                    #expect(model.requestCount == expected.count)
                }
            }
        }
    }

    @Test(arguments: [
        "0", "-0", "1", "9007199254740993", "9223372036854775807", "9223372036854775808",
        "18446744073709551615", "-9223372036854775808", "-1", "12.6", "12.5", "12.4999999999999999",
        "1e3", "1e-3", "-0.0", "9223372036854775807.0", "9.223372036854775807e18",
        "1.7976931348623157e308", "true", "false", "null", "{}", "[]",
        #""12.6""#, #""+12""#, #"" 12 ""#, #""NaN""#, #""Infinity""#,
    ])
    func `token lexemes retain legacy integer and rounded fallback semantics`(literal: String) throws {
        let data = Data("{\"usage\":{\"input\":\(literal)}}".utf8)
        let legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parsed = try #require(PiSessionCostJSON.parse(data))
        let legacyUsage = try #require(legacy["usage"] as? [String: Any])
        let usage = try #require(parsed["usage"] as? [String: Any])
        #expect(PiSessionCostScanner.readNonNegativeInt(usage["input"]) ==
            PiSessionCostScanner.readNonNegativeInt(legacyUsage["input"]))
    }

    @Test(arguments: [
        "0", "1", "0.005", "0.0000000005", "0.0050000005", "1.2345678901234567890123456789",
        "0.4999999999999999999999", "1e-12", "123456789.987654321", "9007199254740993",
    ])
    func `recorded USD retains the legacy NSNumber double bit pattern`(literal: String) throws {
        let data = Data("{\"usage\":{\"cost\":{\"total\":\(literal)}}}".utf8)
        let legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let legacyUsage = try #require(legacy["usage"] as? [String: Any])
        let legacyCost = try #require(legacyUsage["cost"] as? [String: Any])
        let expected = try #require(legacyCost["total"] as? NSNumber)
        let parsed = try #require(PiSessionCostJSON.parse(data))
        let usage = try #require(parsed["usage"] as? [String: Any])
        let cost = try #require(usage["cost"] as? [String: Any])
        let number = try #require(cost["total"] as? PiSessionJSONNumber)
        #expect(number.foundationNumber?.doubleValue.bitPattern == expected.doubleValue.bitPattern)
    }

    @Test
    func `walker retains accounting fields and skips content and thinking trees`() throws {
        let text = #"""
        {"ty\u0070e":"message","id":"turn","timestamp":1793570000,"message":{
          "role":"assistant","provider":"xai","model":"grok-4.7",
          "content":[{"text":"ignored \uD83D\uDE80","nested":{"input":999}}],
          "thinking":{"usage":{"input":999}},"usage":{"input":12,"output":"2.6",
          "cttl":{"ephemeral1h":4,"ignored":[1,2,3]},"cost":{"total":0.123456789,"input":123}}}}
        """#
        let parsed = try #require(PiSessionCostJSON.parse(Data(text.utf8)))
        #expect(parsed["type"] as? String == "message")
        let message = try #require(parsed["message"] as? [String: Any])
        #expect(message["content"] == nil)
        #expect(message["thinking"] == nil)
        let usage = try #require(message["usage"] as? [String: Any])
        #expect(PiSessionCostScanner.readNonNegativeInt(usage["input"]) == 12)
        #expect(PiSessionCostScanner.readNonNegativeInt(usage["output"]) == 3)
        let cttl = try #require(usage["cttl"] as? [String: Any])
        #expect(cttl["ignored"] == nil)
        let cost = try #require(usage["cost"] as? [String: Any])
        #expect(cost["input"] == nil)
    }

    @Test(arguments: [
        #"{"type":"message","ignored":{"x":tru}}"#,
        #"{"type":"message","ignored":[1 2]}"#,
        #"{"type":"message","ignored":"\q"}"#,
        #"{"type":"message","ignored":"\uD800"}"#,
        #"{"type":"message","ignored":01}"#,
        #"{"type":"message","ignored":1e}"#,
        #"{"type":"message","ignored":1e999}"#,
        #"{"type":"message"}false"#,
    ])
    func `malformed skipped values invalidate the entire record`(text: String) {
        #expect(PiSessionCostJSON.parse(Data(text.utf8)) == nil)
    }

    @Test(arguments: [false, true])
    func `malformed structurally complete Pi EOF tail retains the previous snapshot`(newline: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 11, day: 1)
        let valid = """
        {"type":"message","timestamp":"\(env.isoString(for: day))","message":{\
        "role":"assistant","provider":"xai","model":"grok-4.7","usage":{"input":100,"output":10}}}
        """ + "\n"
        let file = try env.writePiSessionFile(relativePath: "tail.jsonl", contents: valid)
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot, refreshMinIntervalSeconds: 0)
        let before = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .grok, since: day, until: day, now: day, options: options, checkCancellation: nil)
        #expect(before.isComplete)
        let cached = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        let malformed = #"{"type":"message","message":{"role":"assistant",,"usage":{"input":999}}}"#
        try (valid + malformed + (newline ? "\n" : "")).write(to: file, atomically: true, encoding: .utf8)
        let after = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .grok,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options,
            checkCancellation: nil)
        #expect(!after.isComplete)
        #expect(after.report.data == before.report.data)
        #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot) == cached)
    }
}
