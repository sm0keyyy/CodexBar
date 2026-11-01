import CodexBarCore
import Foundation

enum GroupedDailyCost {
    enum Value: Equatable {
        case exact(Double), zero, loading, unpriced
        case estimate(Double, unpricedModels: [String])

        var usd: Double? {
            switch self {
            case let .exact(value), let .estimate(value, _): value
            case .zero: 0
            case .loading, .unpriced: nil
            }
        }
    }

    struct ProviderCostInput {
        let name: String
        let value: Value
        var pricingNote: String?
    }

    struct Summary {
        let totalUSD: Double?
        let displayText: String?
        let lines: [String]

        func isOverBudget(_ budget: Double) -> Bool {
            budget > 0 && self.totalUSD.map { $0 > budget } == true
        }
    }

    static func summary(inputs: [ProviderCostInput], preferredCurrency: String = "USD") -> Summary {
        let values = inputs.compactMap(\.value.usd)
        let total = values.isEmpty ? nil : values.reduce(0, +)
        let format = { (usd: Double) in
            UsageFormatter.convertedCostString(usd, preferredCurrency: preferredCurrency, providerCurrency: "USD")
        }
        var parts: [String] = []
        var extra: [String] = []
        for input in inputs {
            switch input.value {
            case let .exact(usd): parts.append("\(input.name) \(format(usd))")
            case .zero: parts.append("\(input.name) \(format(0))")
            case .loading: parts.append("\(input.name): \(L("grouped_icons_tooltip_loading"))")
            case .unpriced: parts.append("\(input.name): \(L("grouped_icons_tooltip_unpriced"))")
            case let .estimate(usd, models):
                parts.append("\(input.name) ≈\(format(usd)) (\(L("grouped_icons_tooltip_estimate")))")
                extra += models.map { L("grouped_icons_tooltip_no_price", input.name, $0) }
                if let note = input.pricingNote { extra.append(note) }
            }
        }
        var lines = total.map { [L("grouped_icons_tooltip_today", format($0))] } ?? []
        if !parts.isEmpty { lines.append(parts.joined(separator: " · ")) }
        lines += extra
        return Summary(totalUSD: total, displayText: total.map(format), lines: lines)
    }
}
