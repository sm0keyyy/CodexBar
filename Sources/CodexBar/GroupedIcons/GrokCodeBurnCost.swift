import CodexBarCore
import CoreFoundation
import Foundation

struct GrokDayCost: Equatable, Sendable {
    var usd: Double = 0
    var estimated = false
    var unpricedModels: [String] = []
    var requestCount = 0
}

enum GrokCodeBurnCost {
    struct Session: Sendable {
        let id: String
        let summary: String
        let signals: String
        let updates: String
    }

    static func today(unifiedLog: String, sessions: [Session], now: Date, calendar: Calendar) -> GrokDayCost {
        let summaries = sessions.reduce(into: [String: String]()) { models, session in
            let summary = self.object(session.summary)
            if let model = summary["current_model_id"] as? String {
                models[session.id] = model
                if let id = (summary["info"] as? [String: Any])?["id"] as? String { models[id] = model }
            }
        }
        var result = GrokDayCost()
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
                      let date = self.date(timestamp), calendar.isDate(date, inSameDayAs: now) else { continue }
                let cached = min(self.number(context["cached_prompt_tokens"]) ?? 0, prompt)
                let model = models[sid] ?? catalog[pid] ?? summaries[sid]
                self.add(
                    model: model ?? "grok-build",
                    tokens: .init(fresh: prompt - cached, output: completion, cacheRead: cached, cacheCreation: 0),
                    estimated: model == nil,
                    to: &result)
            }
        }
        for session in sessions {
            let summary = self.object(session.summary)
            let id = (summary["info"] as? [String: Any])?["id"] as? String ?? session.id
            guard !loggedSessions.contains(id), !loggedSessions.contains(session.id),
                  let timestamp =
                  (summary["updated_at"] ?? summary["last_active_at"] ?? summary["created_at"]) as? String,
                  let date = self.date(timestamp), calendar.isDate(date, inSameDayAs: now) else { continue }
            let signals = self.object(session.signals)
            let model = summary["current_model_id"] as? String ?? signals["primaryModelId"] as? String
                ?? (signals["modelsUsed"] as? [String])?.first ?? "grok-build"
            self.addSession(session, model: model, to: &result)
        }
        result.unpricedModels.sort()
        return result
    }

    private struct CompletedUsage {
        let values: [String: Any]
        let models: [String]
    }

    private static func addSession(_ session: Session, model: String, to result: inout GrokDayCost) {
        var turns: [String: (first: Double, last: Double)] = [:]
        var completed: [String: CompletedUsage] = [:]
        var order: [String] = []
        var previous: Double = -1
        var peak: Double = 0
        var fresh: Double = 0
        var counter = 0
        for line in session.updates.split(whereSeparator: \.isNewline) {
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
            let selected = modelIDs.first { GroupedCostPriceTable.rates(model: $0) != nil }
                ?? (GroupedCostPriceTable.rates(model: model) != nil ? model : modelIDs.first ?? model)
            self.add(
                model: selected,
                tokens: .init(fresh: input, output: output, cacheRead: cached, cacheCreation: creation),
                estimated: turns.keys.contains { completed[$0] == nil },
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
                to: &result)
        }
    }

    private static func add(
        model: String,
        tokens: GroupedCostPriceTable.Tokens,
        estimated: Bool,
        to result: inout GrokDayCost)
    {
        if let cost = GroupedCostPriceTable.cost(model: model, tokens: tokens) {
            result.usd += cost
        } else if !result.unpricedModels.contains(model) { result.unpricedModels.append(model) }
        result.estimated = result.estimated || estimated
        result.requestCount += 1
    }

    private static func object(_ text: String) -> [String: Any] {
        // Malformed JSONL records are ignored, matching CodeBurn's parser.
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
