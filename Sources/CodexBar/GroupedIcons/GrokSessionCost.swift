import CodexBarCore
import CoreFoundation
import Foundation

struct GrokDayCost: Equatable, Sendable {
    var usd: Double = 0
    var estimated = false
    var unpricedModels: [String] = []
    var requestCount = 0
    var modelUSD: [String: Double] = [:]
    var totalTokens: Double = 0
}

enum GrokSessionCost {
    struct Session: Sendable {
        let id: String
        let summaryID: String
        let model: String?
        let updatedAt: Date?
        let cost: GrokDayCost

        init(
            id: String,
            summary: String,
            signals: String,
            updates: String,
            pricing: CostUsagePricing.GrokResolver = .init())
        {
            let summary = GrokSessionCost.object(summary)
            let signals = GrokSessionCost.object(signals)
            self.id = id
            self.summaryID = (summary["info"] as? [String: Any])?["id"] as? String ?? id
            self.model = summary["current_model_id"] as? String
            self.updatedAt = ((summary["updated_at"] ?? summary["last_active_at"] ?? summary["created_at"]) as? String)
                .flatMap(GrokSessionCost.date)
            let model = self.model ?? signals["primaryModelId"] as? String
                ?? (signals["modelsUsed"] as? [String])?.first ?? "grok-build"
            var cost = GrokDayCost()
            GrokSessionCost.addSession(updates: updates, model: model, pricing: pricing, to: &cost)
            self.cost = cost
        }
    }

    static func daily(
        unifiedLog: String,
        sessions: [Session],
        now: Date,
        calendar: Calendar,
        days: Int,
        pricing: CostUsagePricing.GrokResolver = .init()) -> [String: GrokDayCost]
    {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [:] }
        let summaries = sessions.reduce(into: [String: String]()) { models, session in
            if let model = session.model {
                models[session.id] = model
                models[session.summaryID] = model
            }
        }
        var result: [String: GrokDayCost] = [:]
        var catalog: [String: String] = [:]
        var models: [String: String] = [:]
        var loggedSessions = Set<String>()
        var seen = Set<String>()
        for line in unifiedLog.split(whereSeparator: \.isNewline) {
            guard line.contains("shell.turn.inference_done") || line.contains("model changed")
                || line.contains("model catalog: notifying clients") else { continue }
            let record = self.object(String(line))
            let context = record["ctx"] as? [String: Any] ?? [:]
            let message = record["msg"] as? String
            let pid = record["pid"].map { String(describing: $0) } ?? ""
            if message == "model catalog: notifying clients", let model = context["current_model_id"] as? String {
                catalog[pid] = model
            } else if message == "model changed", let sid = record["sid"] as? String,
                      let model = context["model"] as? String
            {
                models[sid] = model
            } else if message == "shell.turn.inference_done",
                      let sid = record["sid"] as? String, !sid.isEmpty,
                      let timestamp = record["ts"] as? String,
                      let prompt = self.number(context["prompt_tokens"]),
                      let completion = self.number(context["completion_tokens"]), prompt > 0 || completion > 0
            {
                loggedSessions.insert(sid)
                let loop = context["loop_index"].map { String(describing: $0) } ?? "1"
                guard seen.insert("\(sid):\(timestamp):\(loop)").inserted,
                      let date = self.date(timestamp), date >= start, date < end,
                      let day = GrokLocalSessionScanner.dayKey(for: date, calendar: calendar) else { continue }
                let cached = min(self.number(context["cached_prompt_tokens"]) ?? 0, prompt)
                let model = models[sid] ?? catalog[pid] ?? summaries[sid]
                self.add(
                    model: model ?? "grok-build",
                    tokens: .init(fresh: prompt - cached, output: completion, cacheRead: cached, cacheCreation: 0),
                    estimated: model == nil,
                    pricing: pricing,
                    to: &result[day, default: GrokDayCost()])
            }
        }
        for session in sessions {
            guard !loggedSessions.contains(session.summaryID), !loggedSessions.contains(session.id),
                  let date = session.updatedAt, date >= start, date < end, session.cost.requestCount > 0,
                  let day = GrokLocalSessionScanner.dayKey(for: date, calendar: calendar) else { continue }
            var cost = result[day, default: GrokDayCost()]
            cost.usd += session.cost.usd
            cost.totalTokens = self.sum(cost.totalTokens, session.cost.totalTokens)
            cost.requestCount += session.cost.requestCount
            cost.estimated = cost.estimated || session.cost.estimated
            cost.unpricedModels = Array(Set(cost.unpricedModels + session.cost.unpricedModels)).sorted()
            for (model, usd) in session.cost.modelUSD {
                cost.modelUSD[model, default: 0] += usd
            }
            result[day] = cost
        }
        for day in result.keys {
            result[day]?.unpricedModels.sort()
        }
        return result
    }

    private struct CompletedUsage {
        let values: [String: Any]
        let models: [String]
    }

    private static func addSession(
        updates: String,
        model: String,
        pricing: CostUsagePricing.GrokResolver,
        to result: inout GrokDayCost)
    {
        var turns: [String: (first: Double, last: Double)] = [:]
        var completed: [String: CompletedUsage] = [:]
        var order: [String] = []
        var previous: Double = -1
        var peak: Double = 0
        var fresh: Double = 0
        var counter = 0
        for line in updates.split(whereSeparator: \.isNewline) {
            let params = self.object(String(line))["params"] as? [String: Any] ?? [:]
            let meta = params["_meta"] as? [String: Any] ?? [:]
            if let total = self.number(meta["totalTokens"]) {
                if previous >= 0, total < previous * 0.5 { fresh = self.sum(fresh, peak); peak = 0 }
                peak = max(peak, total)
                previous = total
                if let prompt = meta["promptId"] as? String, !prompt.isEmpty {
                    turns[prompt] = (turns[prompt]?.first ?? total, total)
                }
            }
            guard let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any] else { continue }
            let prompt = (update["prompt_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "turn_completed:\(counter)"
            counter += 1
            if completed[prompt] == nil { order.append(prompt) }
            let modelUsage = usage["modelUsage"] as? [String: Any] ?? [:]
            let modelText = line.range(of: "\"modelUsage\"").map { String(line[$0.upperBound...]) } ?? ""
            let modelIDs = modelUsage.keys.filter { key in
                guard let values = modelUsage[key] as? [String: Any] else { return false }
                return ["inputTokens", "outputTokens", "cachedReadTokens", "cacheCreationTokens", "reasoningTokens"]
                    .contains { self.number(values[$0]) != nil }
            }.sorted {
                (modelText.range(of: "\"\($0)\"")?.lowerBound ?? modelText.endIndex)
                    < (modelText.range(of: "\"\($1)\"")?.lowerBound ?? modelText.endIndex)
            }
            completed[prompt] = CompletedUsage(values: usage, models: modelIDs)
        }
        var input: Double = 0
        var output: Double = 0
        var cached: Double = 0
        var creation: Double = 0
        var modelIDs: [String] = []
        for key in order {
            guard let usage = completed[key] else { continue }
            let read = self.number(usage.values["cachedReadTokens"]) ?? 0
            let write = self.number(usage.values["cacheCreationTokens"]) ?? 0
            input = self.sum(input, max(0, (self.number(usage.values["inputTokens"]) ?? 0) - read - write))
            output = self.sum(output, self.number(usage.values["outputTokens"]) ?? 0)
            cached = self.sum(cached, read)
            creation = self.sum(creation, write)
            for id in usage.models where !modelIDs.contains(id) {
                modelIDs.append(id)
            }
        }
        if input + output + cached + creation > 0 {
            let selected = modelIDs.first { pricing.rates(model: $0) != nil }
                ?? (pricing.rates(model: model) != nil ? model : modelIDs.first ?? model)
            self.add(
                model: selected,
                tokens: .init(fresh: input, output: output, cacheRead: cached, cacheCreation: creation),
                // Session rollups lack the individual request sizes needed to select context tiers.
                estimated: true,
                pricing: pricing,
                to: &result)
        } else {
            fresh = self.sum(fresh, peak)
            let firsts = turns.values.reduce(0) { self.sum($0, $1.first) }
            output = turns.values.reduce(0) { self.sum($0, max(0, $1.last - $1.first)) }
            guard fresh + output > 0 else { return }
            self.add(
                model: model,
                tokens: .init(fresh: fresh, output: output, cacheRead: max(0, firsts - fresh), cacheCreation: 0),
                estimated: true,
                pricing: pricing,
                to: &result)
        }
    }

    private static func add(
        model: String,
        tokens: CostUsagePricing.GrokTokens,
        estimated: Bool,
        pricing: CostUsagePricing.GrokResolver,
        to result: inout GrokDayCost)
    {
        if let cost = pricing.cost(model: model, tokens: tokens) {
            result.usd += cost
            result.modelUSD[model, default: 0] += cost
        } else if !result.unpricedModels.contains(model) { result.unpricedModels.append(model) }
        result.estimated = result.estimated || estimated
        result.requestCount += 1
        result.totalTokens = self.sum(
            result.totalTokens, tokens.fresh + tokens.output + tokens.cacheRead + tokens.cacheCreation)
    }

    private static func object(_ text: String) -> [String: Any] {
        // Ignore malformed JSONL records while retaining other usage from the session.
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? min(value, 9_007_199_254_740_991) : nil
    }

    private static func sum(_ lhs: Double, _ rhs: Double) -> Double { min(lhs + rhs, 9_007_199_254_740_991) }

    private static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
