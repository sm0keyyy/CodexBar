import Foundation

enum GrokPriceTable {
    static let verifiedOn = "2026-11-01"
    static let snapshotCommit = "9d9ac21d"

    struct Rates {
        let input: Double
        let output: Double
        let cached: Double
    }

    private static let rows: [String: Rates] = [
        "grok-4.7": Rates(input: 2, output: 6, cached: 0.5),
        "grok-4.6": Rates(input: 2, output: 6, cached: 0.5),
        "grok-4.5": Rates(input: 2, output: 6, cached: 0.3),
        "grok-4.5-latest": Rates(input: 2, output: 6, cached: 0.3),
        "grok-build-latest": Rates(input: 2, output: 6, cached: 0.3),
        "grok-build-0.1": Rates(input: 1, output: 2, cached: 0.2),
        "grok-code-fast-1": Rates(input: 1, output: 2, cached: 0.2),
    ]
    private static let keys = GrokPriceTable.rows.keys.sorted { $0.count > $1.count }

    static func rates(model: String, promptTokens: Double = 0) -> Rates? {
        var canonical = model.hasPrefix("xai/") ? String(model.dropFirst(4)) : model
        if canonical == "grok-build" { canonical = "grok-build-0.1" }
        if canonical == "grok-4.6", promptTokens >= 200_000 {
            return Rates(input: 4, output: 12, cached: 1)
        }
        if let exact = self.rows[canonical] { return exact }
        return self.keys.first { canonical.hasPrefix($0 + "-") }.flatMap { self.rows[$0] }
    }

    struct Tokens {
        let fresh: Double
        let output: Double
        let cacheRead: Double
        let cacheCreation: Double
    }

    static func cost(model: String, tokens: Tokens) -> Double? {
        guard let rates = self.rates(model: model, promptTokens: tokens.fresh + tokens.cacheRead) else { return nil }
        return ((tokens.fresh + tokens.cacheCreation) * rates.input
            + tokens.output * rates.output + tokens.cacheRead * rates.cached) / 1_000_000
    }
}
