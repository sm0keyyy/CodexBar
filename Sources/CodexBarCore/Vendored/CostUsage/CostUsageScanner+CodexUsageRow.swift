import Foundation

/// Rows own this table for one transcript scan or cache read, never for the process lifetime.
final class CodexUsageRowStringTable: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "codexUsageRowStringTable")!

    private struct UTF8Key: Hashable {
        let value: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.value.utf8.elementsEqual(rhs.value.utf8)
        }

        func hash(into hasher: inout Hasher) {
            // String's canonical equality must not merge different persisted Unicode spellings.
            for byte in self.value.utf8 {
                hasher.combine(byte)
            }
        }
    }

    private let lock = NSLock()
    private var ids: [UTF8Key: UInt32] = [:]
    private var strings: [String] = [""] // Zero represents an absent optional, not an empty string.

    func id(for value: String?) -> UInt32 {
        guard let value else { return 0 }
        return self.lock.withLock {
            let key = UTF8Key(value: value)
            if let id = self.ids[key] { return id }
            let id = UInt32(self.strings.count)
            self.strings.append(value)
            self.ids[key] = id
            return id
        }
    }

    func value(for id: UInt32) -> String {
        self.lock.withLock { self.strings[Int(id)] }
    }

    func optionalValue(for id: UInt32) -> String? {
        id == 0 ? nil : self.value(for: id)
    }
}

extension CostUsageScanner {
    struct CodexUsageRow: Codable, Equatable {
        private let stringTable: CodexUsageRowStringTable
        private let dayID: UInt32
        private let modelID: UInt32
        private let rawModelID: UInt32
        private var pricingModelID: UInt32
        private var pricingModeID: UInt32

        var day: String {
            self.stringTable.value(for: self.dayID)
        }

        var model: String {
            self.stringTable.value(for: self.modelID)
        }

        var rawModel: String? {
            self.stringTable.optionalValue(for: self.rawModelID)
        }

        var pricingModel: String? {
            get { self.stringTable.optionalValue(for: self.pricingModelID) }
            set { self.pricingModelID = self.stringTable.id(for: newValue) }
        }

        var pricingMode: String? {
            get { self.stringTable.optionalValue(for: self.pricingModeID) }
            set { self.pricingModeID = self.stringTable.id(for: newValue) }
        }

        var turnID: String?
        let eventIndex: Int?
        let timestampUnixMs: Int64?
        let input: Int
        let cached: Int
        let output: Int
        let reasoning: Int?
        let responseID: String?
        let requestMirrorKeys: [String]?
        /// Only authoritative source costs are stored. Reports resolve estimated prices from tokens.
        var knownCostNanos: Int64?
        var unpricedTokens: Int?
        /// Classified on report copies only; never written to the cache.
        var isIncludedInPlan: Bool?

        init(
            day: String,
            model: String,
            rawModel: String? = nil,
            turnID: String?,
            eventIndex: Int?,
            timestampUnixMs: Int64? = nil,
            input: Int,
            cached: Int,
            output: Int,
            reasoning: Int? = nil,
            knownCostNanos: Int64? = nil,
            unpricedTokens: Int? = nil,
            pricingModel: String? = nil,
            pricingMode: String? = nil,
            responseID: String? = nil,
            requestMirrorKeys: [String]? = nil,
            stringTable: CodexUsageRowStringTable = CodexUsageRowStringTable())
        {
            self.stringTable = stringTable
            self.dayID = stringTable.id(for: day)
            self.modelID = stringTable.id(for: model)
            self.rawModelID = stringTable.id(for: rawModel)
            self.pricingModelID = stringTable.id(for: pricingModel)
            self.pricingModeID = stringTable.id(for: pricingMode)
            self.turnID = turnID
            self.eventIndex = eventIndex
            self.timestampUnixMs = timestampUnixMs
            self.input = input
            self.cached = cached
            self.output = output
            self.reasoning = reasoning.map { min(max(0, $0), max(0, output)) }
            self.responseID = responseID
            self.requestMirrorKeys = requestMirrorKeys
            self.knownCostNanos = knownCostNanos
            self.unpricedTokens = unpricedTokens
        }

        private enum CodingKeys: String, CodingKey {
            case day, model, rawModel, turnID, eventIndex, timestampUnixMs, input, cached, output, reasoning
            case responseID, requestMirrorKeys, knownCostNanos, unpricedTokens, pricingModel, pricingMode
            case isIncludedInPlan
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let table = decoder.userInfo[CodexUsageRowStringTable.key] as? CodexUsageRowStringTable
                ?? CodexUsageRowStringTable()
            self.stringTable = table
            self.dayID = try table.id(for: values.decode(String.self, forKey: .day))
            self.modelID = try table.id(for: values.decode(String.self, forKey: .model))
            self.rawModelID = try table.id(for: values.decodeIfPresent(String.self, forKey: .rawModel))
            self.pricingModelID = try table.id(for: values.decodeIfPresent(String.self, forKey: .pricingModel))
            self.pricingModeID = try table.id(for: values.decodeIfPresent(String.self, forKey: .pricingMode))
            self.turnID = try values.decodeIfPresent(String.self, forKey: .turnID)
            self.eventIndex = try values.decodeIfPresent(Int.self, forKey: .eventIndex)
            self.timestampUnixMs = try values.decodeIfPresent(Int64.self, forKey: .timestampUnixMs)
            self.input = try values.decode(Int.self, forKey: .input)
            self.cached = try values.decode(Int.self, forKey: .cached)
            self.output = try values.decode(Int.self, forKey: .output)
            // Decoding preserves stored counters, including legacy values outside initializer clamps.
            self.reasoning = try values.decodeIfPresent(Int.self, forKey: .reasoning)
            self.responseID = try values.decodeIfPresent(String.self, forKey: .responseID)
            self.requestMirrorKeys = try values.decodeIfPresent([String].self, forKey: .requestMirrorKeys)
            self.knownCostNanos = try values.decodeIfPresent(Int64.self, forKey: .knownCostNanos)
            self.unpricedTokens = try values.decodeIfPresent(Int.self, forKey: .unpricedTokens)
            self.isIncludedInPlan = try values.decodeIfPresent(Bool.self, forKey: .isIncludedInPlan)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(self.day, forKey: .day)
            try values.encode(self.model, forKey: .model)
            try values.encodeIfPresent(self.rawModel, forKey: .rawModel)
            try values.encodeIfPresent(self.turnID, forKey: .turnID)
            try values.encodeIfPresent(self.eventIndex, forKey: .eventIndex)
            try values.encodeIfPresent(self.timestampUnixMs, forKey: .timestampUnixMs)
            try values.encode(self.input, forKey: .input)
            try values.encode(self.cached, forKey: .cached)
            try values.encode(self.output, forKey: .output)
            try values.encodeIfPresent(self.reasoning, forKey: .reasoning)
            try values.encodeIfPresent(self.responseID, forKey: .responseID)
            try values.encodeIfPresent(self.requestMirrorKeys, forKey: .requestMirrorKeys)
            try values.encodeIfPresent(self.knownCostNanos, forKey: .knownCostNanos)
            try values.encodeIfPresent(self.unpricedTokens, forKey: .unpricedTokens)
            try values.encodeIfPresent(self.pricingModel, forKey: .pricingModel)
            try values.encodeIfPresent(self.pricingMode, forKey: .pricingMode)
            try values.encodeIfPresent(self.isIncludedInPlan, forKey: .isIncludedInPlan)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.day == rhs.day && lhs.model == rhs.model && lhs.rawModel == rhs.rawModel
                && lhs.pricingModel == rhs.pricingModel && lhs.pricingMode == rhs.pricingMode
                && lhs.turnID == rhs.turnID && lhs.eventIndex == rhs.eventIndex
                && lhs.timestampUnixMs == rhs.timestampUnixMs && lhs.input == rhs.input
                && lhs.cached == rhs.cached && lhs.output == rhs.output && lhs.reasoning == rhs.reasoning
                && lhs.responseID == rhs.responseID && lhs.requestMirrorKeys == rhs.requestMirrorKeys
                && lhs.knownCostNanos == rhs.knownCostNanos && lhs.unpricedTokens == rhs.unpricedTokens
                && lhs.isIncludedInPlan == rhs.isIncludedInPlan
        }
    }
}
