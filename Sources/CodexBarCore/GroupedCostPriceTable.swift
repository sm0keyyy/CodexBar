package enum GroupedCostPriceTable {
    package static let verifiedOn = "2026-11-01"
    package static let sourceURL = "https://docs.x.ai/developers/models"

    package struct Rates: Sendable {
        package let input: Double
        package let output: Double
        package let cached: Double
    }

    private static let rows: [String: Rates] = [
        "grok-4.7": Rates(input: 2, output: 6, cached: 0.5),
        "grok-4.6": Rates(input: 2, output: 6, cached: 0.5),
        "grok-4.5": Rates(input: 2, output: 6, cached: 0.3),
        "grok-build-latest": Rates(input: 2, output: 6, cached: 0.3),
        "grok-4.3": Rates(input: 1.25, output: 2.5, cached: 0.2),
        "grok-4.20": Rates(input: 1.25, output: 2.5, cached: 0.2),
        "grok-build-0.1": Rates(input: 1, output: 2, cached: 0.2),
        "grok-code-fast": Rates(input: 1, output: 2, cached: 0.2),
    ]
    private static let keys = GroupedCostPriceTable.rows.keys.sorted { $0.count > $1.count }

    package static func canonicalModel(_ model: String) -> String {
        var canonical = model.lastIndex(of: "/").map { String(model[model.index(after: $0)...]) } ?? model
        if canonical == "grok-build" { canonical = "grok-build-0.1" }
        if canonical == "grok-4.6-high" || canonical == "grok-4.6-high-fast" {
            canonical = "grok-4.6"
        }
        return canonical
    }

    package static func rates(model: String, promptTokens: Double = 0) -> Rates? {
        let canonical = self.canonicalModel(model)
        guard let key = self.rows[canonical] != nil ? canonical : self.keys.first(where: {
            canonical.hasPrefix($0 + "-")
        }), let base = self.rows[key] else { return nil }
        // xAI applies the higher rate to every bucket, not only tokens above the threshold.
        let multiplier: Double = promptTokens >= 200_000 ? 2 : 1
        return Rates(
            input: base.input * multiplier,
            output: base.output * multiplier,
            cached: base.cached * multiplier)
    }
}
