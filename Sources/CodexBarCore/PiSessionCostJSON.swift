import Foundation

/// A numeric lexeme keeps integer counters off Foundation's decimal scanner.
enum PiSessionJSONNumber {
    case integer(Int)
    case lexeme(String)

    var foundationNumber: NSNumber? {
        switch self {
        case let .integer(value):
            NSNumber(value: value)
        case let .lexeme(text):
            // Preserve JSONSerialization's NSNumber-to-Double behavior for recorded USD and rare fractions.
            (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? NSNumber
        }
    }
}

enum PiSessionCostJSON {
    private enum Fields {
        case entry, message, usage, cttl, cost, scalar, ignored

        func value(for key: String) -> Fields {
            switch self {
            case .entry:
                if key == "message" { return .message }
                if key == "usage" { return .usage }
                return Self.entryScalars.contains(key) ? .scalar : .ignored
            case .message:
                if key == "usage" { return .usage }
                return Self.messageScalars.contains(key) ? .scalar : .ignored
            case .usage:
                if key == "cttl" { return .cttl }
                if key == "cost" { return .cost }
                return Self.counters.contains(key) ? .scalar : .ignored
            case .cttl:
                return key == "ephemeral1h" || key == "ephemeral_1h" ? .scalar : .ignored
            case .cost:
                return key == "total" ? .scalar : .ignored
            case .scalar, .ignored:
                return .ignored
            }
        }

        private static let entryScalars: Set<String> = [
            "type", "id", "sessionId", "session_id", "provider", "model", "modelId", "timestamp",
        ]
        private static let messageScalars: Set<String> = ["role", "provider", "model", "modelId", "timestamp"]

        private static let counters: Set<String> = [
            "input", "inputTokens", "input_tokens", "promptTokens", "prompt_tokens",
            "cacheRead", "cacheReadTokens", "cache_read", "cache_read_tokens",
            "cacheReadInputTokens", "cache_read_input_tokens",
            "cacheWrite", "cacheWriteTokens", "cache_write", "cache_write_tokens",
            "cacheCreationTokens", "cache_creation_tokens", "cacheCreationInputTokens", "cache_creation_input_tokens",
            "cacheWrite1h", "cache_write_1h", "output", "outputTokens", "output_tokens",
            "completionTokens", "completion_tokens", "totalTokens", "total_tokens", "tokenCount", "token_count",
            "tokens",
        ]
    }

    static func parse(_ data: Data) -> [String: Any]? {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var walker = Walker(bytes: bytes)
            walker.whitespace()
            guard walker.index < bytes.count, bytes[walker.index] == 0x7B,
                  let object = walker.value(fields: .entry, depth: 0) as? [String: Any] else { return nil }
            walker.whitespace()
            return walker.index == bytes.count ? object : nil
        }
    }

    private struct Walker {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        mutating func value(fields: Fields, depth: Int) -> Any? {
            guard depth < 512, self.index < self.bytes.count else { return nil }
            switch self.bytes[self.index] {
            case 0x7B:
                return self.object(fields: fields, depth: depth)
            case 0x5B:
                self.index += 1
                self.whitespace()
                if self.consume(0x5D) { return NSNull() }
                while self.value(fields: .ignored, depth: depth + 1) != nil {
                    self.whitespace()
                    if self.consume(0x5D) { return NSNull() }
                    guard self.consume(0x2C) else { return nil }
                    self.whitespace()
                }
                return nil
            case 0x22:
                guard let range = self.stringRange() else { return nil }
                if fields == .ignored { return NSNull() }
                return self.string(in: range)
            case 0x74:
                return self.literal("true")
            case 0x66:
                return self.literal("false")
            case 0x6E:
                return self.literal("null")
            default:
                return self.number(retain: fields != .ignored)
            }
        }

        mutating func object(fields: Fields, depth: Int) -> Any? {
            self.index += 1
            self.whitespace()
            var result: [String: Any] = [:]
            if self.consume(0x7D) { return fields == .ignored ? NSNull() : result }
            while let range = self.stringRange() {
                let key = fields == .ignored ? nil : self.string(in: range)
                let selected = key.map { fields.value(for: $0) } ?? .ignored
                self.whitespace()
                guard self.consume(0x3A) else { return nil }
                self.whitespace()
                guard let value = self.value(fields: selected, depth: depth + 1) else { return nil }
                if selected != .ignored, let key { result[key] = value }
                self.whitespace()
                if self.consume(0x7D) { return fields == .ignored ? NSNull() : result }
                guard self.consume(0x2C) else { return nil }
                self.whitespace()
            }
            return nil
        }

        mutating func number(retain: Bool) -> Any? {
            let start = self.index
            _ = self.consume(0x2D)
            guard self.index < self.bytes.count else { return nil }
            if !self.consume(0x30) {
                guard self.bytes[self.index] >= 0x31, self.bytes[self.index] <= 0x39 else { return nil }
                self.digits()
            }
            if self.consume(0x2E) {
                let start = self.index
                self.digits()
                guard self.index > start else { return nil }
            }
            if self.consume(0x65) || self.consume(0x45) {
                if !self.consume(0x2B) { _ = self.consume(0x2D) }
                let start = self.index
                self.digits()
                guard self.index > start else { return nil }
            }
            var integerEnd = start
            if let integer = CostUsageScanner.parseJSONByteInt(
                in: self.bytes, index: &integerEnd, limit: self.index), integerEnd == self.index
            {
                return retain ? PiSessionJSONNumber.integer(integer) : NSNull()
            }
            guard let text = String(bytes: self.bytes[start..<self.index], encoding: .utf8),
                  let double = Double(text), double.isFinite else { return nil }
            return retain ? PiSessionJSONNumber.lexeme(text) : NSNull()
        }

        mutating func digits() {
            while self.index < self.bytes.count, self.bytes[self.index] >= 0x30, self.bytes[self.index] <= 0x39 {
                self.index += 1
            }
        }

        mutating func stringRange() -> (range: Range<Int>, hasEscapes: Bool)? {
            guard let parsed = CostUsageScanner.parseJSONByteStringRange(
                in: self.bytes, index: &self.index, limit: self.bytes.count) else { return nil }
            var cursor = parsed.range.lowerBound
            var hasUTF8 = false
            while cursor < parsed.range.upperBound {
                let byte = self.bytes[cursor]
                guard byte >= 0x20 else { return nil }
                hasUTF8 = hasUTF8 || byte >= 0x80
                cursor += 1
                guard byte == 0x5C else { continue }
                guard cursor < parsed.range.upperBound else { return nil }
                let escape = self.bytes[cursor]
                cursor += 1
                switch escape {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    break
                case 0x75:
                    guard let code = self.hexQuad(cursor, limit: parsed.range.upperBound) else { return nil }
                    cursor += 4
                    if (0xD800...0xDBFF).contains(code) {
                        guard cursor + 6 <= parsed.range.upperBound,
                              self.bytes[cursor] == 0x5C, self.bytes[cursor + 1] == 0x75,
                              let low = self.hexQuad(cursor + 2, limit: parsed.range.upperBound),
                              (0xDC00...0xDFFF).contains(low) else { return nil }
                        cursor += 6
                    } else if (0xDC00...0xDFFF).contains(code) {
                        return nil
                    }
                default:
                    return nil
                }
            }
            if hasUTF8 {
                var decoder = Unicode.UTF8()
                var iterator = self.bytes[parsed.range].makeIterator()
                while true {
                    switch decoder.decode(&iterator) {
                    case .scalarValue: continue
                    case .emptyInput: return parsed
                    case .error: return nil
                    }
                }
            }
            return parsed
        }

        func string(in parsed: (range: Range<Int>, hasEscapes: Bool)) -> String? {
            if parsed.hasEscapes {
                return CostUsageScanner.decodeEscapedJSONByteString(from: self.bytes, in: parsed.range)
            }
            return String(bytes: self.bytes[parsed.range], encoding: .utf8)
        }

        func hexQuad(_ start: Int, limit: Int) -> UInt16? {
            guard start + 4 <= limit else { return nil }
            var value: UInt16 = 0
            for offset in 0..<4 {
                let digit: UInt16
                switch self.bytes[start + offset] {
                case 0x30...0x39: digit = UInt16(self.bytes[start + offset] - 0x30)
                case 0x41...0x46: digit = UInt16(self.bytes[start + offset] - 0x41 + 10)
                case 0x61...0x66: digit = UInt16(self.bytes[start + offset] - 0x61 + 10)
                default: return nil
                }
                value = value * 16 + digit
            }
            return value
        }

        mutating func literal(_ text: StaticString) -> Any? {
            let matched = text.withUTF8Buffer { expected in
                self.index + expected.count <= self.bytes.count &&
                    self.bytes[self.index..<(self.index + expected.count)].elementsEqual(expected)
            }
            guard matched else { return nil }
            self.index += text.utf8CodeUnitCount
            // Booleans and null are present but invalid for every retained scalar field.
            return NSNull()
        }

        mutating func whitespace() {
            while self.index < self.bytes.count {
                switch self.bytes[self.index] {
                case 0x20, 0x09, 0x0A, 0x0D: self.index += 1
                default: return
                }
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard self.index < self.bytes.count, self.bytes[self.index] == byte else { return false }
            self.index += 1
            return true
        }
    }
}
