import CodexBarCore
import Foundation

enum GroupedDailyCost {
    enum Value: Equatable {
        case exact(Double), zero, loading, unpriced
        case estimate(Double, unpricedModels: [String])

        var usd: Double? {
            switch self {
            case let .exact(value): value
            case let .estimate(value, models): value == 0 && !models.isEmpty ? nil : value
            case .zero: 0
            case .loading, .unpriced: nil
            }
        }
    }

    struct ProviderCostInput {
        let name: String
        let value: Value
    }

    struct Summary: Equatable {
        let totalUSD: Double?
        let displayText: String?
        let lines: [String]

        func isOverBudget(_ budget: Double) -> Bool {
            budget > 0 && self.totalUSD.map { $0 > budget } == true
        }
    }

    struct Slot {
        private var day: Date?
        private var providers: [String] = []
        private var lastCompleteTotal: Double?

        mutating func resolve(
            inputs: [ProviderCostInput],
            isReloading: Bool,
            preferredCurrency: String,
            now: Date,
            calendar: Calendar = .current) -> (text: String?, totalUSD: Double?, dimmed: Bool)
        {
            let day = calendar.startOfDay(for: now)
            let providers = inputs.map(\.name)
            if self.day != day || self.providers != providers {
                self.lastCompleteTotal = nil
                self.day = day
                self.providers = providers
            }
            let summary = GroupedDailyCost.summary(inputs: inputs, preferredCurrency: preferredCurrency)
            let loading = isReloading || inputs.contains { $0.value == .loading }
            if !loading, !inputs.isEmpty, inputs.allSatisfy({ $0.value.usd != nil }) {
                self.lastCompleteTotal = summary.totalUSD
            }
            if loading, let total = self.lastCompleteTotal {
                return (GroupedDailyCost.displayText(usd: total, preferredCurrency: preferredCurrency), total, true)
            }
            return (summary.displayText, summary.totalUSD, false)
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
                if usd == 0, !models.isEmpty {
                    parts.append("\(input.name): \(L("grouped_icons_tooltip_unpriced"))")
                } else {
                    parts.append("\(input.name) ≈\(format(usd)) (\(L("grouped_icons_tooltip_estimate")))")
                }
                extra += models.map { L("grouped_icons_tooltip_no_price", input.name, $0) }
            }
        }
        var lines: [String] = []
        if let total {
            lines.append(([L("grouped_icons_tooltip_today", format(total))] + parts).joined(separator: " · "))
        } else if !parts.isEmpty {
            lines.append(parts.joined(separator: " · "))
        }
        lines += extra
        return Summary(
            totalUSD: total,
            displayText: total.map { self.displayText(usd: $0, preferredCurrency: preferredCurrency) },
            lines: lines)
    }

    static func displayText(usd: Double, preferredCurrency: String) -> String {
        let converted = UsageFormatter.convertedCost(
            usd, preferredCurrency: preferredCurrency, providerCurrency: "USD")
        if converted.value >= 10000 {
            return UsageFormatter.compactCurrencyString(
                floor(converted.value / 1000), currencyCode: converted.currencyCode) + "k"
        }
        return converted.value >= 100
            ? UsageFormatter.compactCurrencyString(floor(converted.value), currencyCode: converted.currencyCode)
            : UsageFormatter.currencyString(converted.value, currencyCode: converted.currencyCode)
    }

    static func reservedDisplayTexts(preferredCurrency: String) -> [String] {
        let currency = UsageFormatter.convertedCost(
            0, preferredCurrency: preferredCurrency, providerCurrency: "USD").currencyCode
        return [
            UsageFormatter.currencyString(99.99, currencyCode: currency),
            UsageFormatter.compactCurrencyString(9999, currencyCode: currency),
        ]
    }
}
