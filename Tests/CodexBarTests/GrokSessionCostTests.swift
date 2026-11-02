import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct GrokSessionCostTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        return calendar
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_793_568_000)
    }

    private func request(
        model: String? = nil,
        prompt: Int = 300_000,
        cached: Int = 250_000,
        timestamp: String = "2026-11-01T18:00:00Z") -> String
    {
        let change = model.map { "{\"msg\":\"model changed\",\"sid\":\"s1\",\"ctx\":{\"model\":\"\($0)\"}}\n" } ?? ""
        return change + """
        {"msg":"shell.turn.inference_done","sid":"s1","pid":123,"ts":"\(timestamp)",\
        "ctx":{"prompt_tokens":\(prompt),"cached_prompt_tokens":\(cached),"completion_tokens":10000,\
        "reasoning_tokens":4000,"loop_index":1}}
        """
    }

    private func scan(_ log: String = "", sessions: [GrokSessionCost.Session] = []) -> GrokDayCost {
        GrokSessionCost.today(
            unifiedLog: log,
            sessions: sessions,
            now: self.now,
            calendar: self.calendar,
            pricing: .init(catalog: nil))
    }

    private func session(
        updates: String,
        model: String = "grok-4.6",
        id: String = "s1",
        date: String = "2026-11-01T18:00:00Z") -> GrokSessionCost.Session
    {
        .init(
            id: id,
            summary: "{\"info\":{\"id\":\"\(id)\"},\"updated_at\":\"\(date)\",\"current_model_id\":\"\(model)\"}",
            signals: "{}",
            updates: updates)
    }

    private func completed(
        input: Int,
        cached: Int,
        output: Int,
        model: String = "grok-4.6-build",
        prompt: String = "p1") -> String
    {
        """
        {"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"\(prompt)","usage":{\
        "inputTokens":\(input),"cachedReadTokens":\(cached),"outputTokens":\(output),"reasoningTokens":18747,\
        "modelUsage":{"\(model)":{"inputTokens":\(input)}}}}}}
        """
    }

    @Test func `unified requests use per request tiers and never double price reasoning`() {
        #expect(abs(self.scan(self.request(model: "grok-4.6")).usd - 0.57) < 0.00000001)
        #expect(!self.scan(self.request(model: "grok-4.6")).estimated)
        let catalog = "{\"msg\":\"model catalog: notifying clients\",\"pid\":123,"
            + "\"ctx\":{\"current_model_id\":\"grok-4.7\"}}\n"
        #expect(abs(self.scan(catalog + self.request()).usd - 0.57) < 0.00000001)
        #expect(abs(self.scan(self.request(model: "grok-4.6", prompt: 150_000, cached: 100_000)).usd - 0.21)
            < 0.00000001)
        let log = self.request(model: "grok-4.6")
        #expect(self.scan(log + "\n" + log).requestCount == 1)
        #expect(abs(self.scan(catalog + log).usd - 0.57) < 0.00000001)
    }

    @Test func `model fallback retains session identity without counting rotated logs twice`() {
        let session = self.session(updates: self.completed(input: 3_784_207, cached: 3_020_544, output: 21146))
        #expect(abs(self.scan(sessions: [session]).usd - 6.328948) < 0.00000001)
        #expect(self.scan(sessions: [session]).estimated)
        let log = self.request(model: "grok-4.6")
        #expect(self.scan(log, sessions: [session]).requestCount == 1)
        #expect(abs(self.scan(self.request(), sessions: [session]).usd - 0.57) < 0.00000001)
        #expect(self.scan(self.request()).estimated)
        let unknown = self.scan(self.request(model: "unknown-model"))
        #expect(unknown.usd == 0)
        #expect(unknown.unpricedModels == ["unknown-model"])
        #expect(GroupedCostPriceTable.rates(model: "xai/grok-build")?.input == 1)
        #expect(GroupedCostPriceTable.rates(model: "grok-build-latest")?.cached == 0.3)
    }

    @Test func `completed turns use last record and legacy compaction retains segment peaks`() {
        let first = self.completed(input: 1000, cached: 0, output: 100)
        let last = self.completed(input: 2000, cached: 0, output: 200)
        #expect(self.scan(sessions: [self.session(updates: first + "\n" + last)]).usd
            == self.scan(sessions: [self.session(updates: last)]).usd)
        let curve = [("p1", 1000), ("p1", 1500), ("p2", 1600), ("p2", 2000), ("p3", 500), ("p3", 900)]
            .map { "{\"params\":{\"_meta\":{\"promptId\":\"\($0.0)\",\"totalTokens\":\($0.1)}}}" }
            .joined(separator: "\n")
        let result = self.scan(sessions: [self.session(updates: curve)])
        #expect(abs(result.usd - 0.0137) < 0.00000001)
        #expect(result.estimated)
        let incomplete = last + "\n{\"params\":{\"_meta\":{\"promptId\":\"unfinished\",\"totalTokens\":500}}}"
        #expect(self.scan(sessions: [self.session(updates: incomplete)]).estimated)
    }

    @Test func `local day excludes yesterday but session totals count on update day`() {
        #expect(self.scan(self.request(model: "grok-4.6", timestamp: "2026-11-01T05:00:00Z")).usd == 0)
        let usage = self.completed(input: 3_784_207, cached: 3_020_544, output: 21146)
        #expect(abs(self.scan(sessions: [self.session(updates: usage)]).usd - 6.328948) < 0.00000001)
        #expect(self.scan(sessions: [self.session(updates: usage, date: "2026-11-01T05:00:00Z")]).usd == 0)
        let yesterday = self.request(model: "grok-4.6", timestamp: "2026-11-01T05:00:00Z")
        #expect(self.scan(yesterday, sessions: [self.session(updates: usage)]).usd == 0)
    }

    @Test func `malformed and negative usage cannot poison the total`() {
        let invalid = """
        not json
        {"msg":"shell.turn.inference_done","sid":"s1","ts":"2026-11-01T18:00:00Z",\
        "ctx":{"prompt_tokens":-1,"completion_tokens":10}}
        {"msg":"shell.turn.inference_done","sid":"s1","ts":"2026-11-01T18:00:00Z",\
        "ctx":{"prompt_tokens":true,"completion_tokens":10}}
        """
        #expect(self.scan(invalid).requestCount == 0)
    }

    @Test(arguments: [
        ("grok-4.7", 2.0, 6.0, 0.5),
        ("grok-4.6-build", 2.0, 6.0, 0.5),
        ("xai/grok-4.5-latest", 2.0, 6.0, 0.3),
        ("xai-oauth/grok-build", 1.0, 2.0, 0.2),
        ("grok-build-0.1", 1.0, 2.0, 0.2),
        ("grok-code-fast-1", 1.0, 2.0, 0.2),
    ])
    func `official rates double every bucket at the inclusive prompt threshold`(
        model: String, input: Double, output: Double, cached: Double)
    {
        let below = GroupedCostPriceTable.rates(model: model, promptTokens: 199_999)
        #expect(below?.input == input)
        #expect(below?.output == output)
        #expect(below?.cached == cached)
        let threshold = GroupedCostPriceTable.rates(model: model, promptTokens: 200_000)
        #expect(threshold?.input == input * 2)
        #expect(threshold?.output == output * 2)
        #expect(threshold?.cached == cached * 2)
    }

    @Test func `cache creation participates in the prompt threshold without a surcharge`() {
        let cost = CostUsagePricing.GrokResolver(catalog: nil).cost(
            model: "grok-build",
            tokens: .init(fresh: 100_000, output: 10000, cacheRead: 50000, cacheCreation: 50000))
        #expect(cost == 0.36)
        #expect(GroupedCostPriceTable.rates(model: "unknown-model", promptTokens: 300_000) == nil)
    }
}
