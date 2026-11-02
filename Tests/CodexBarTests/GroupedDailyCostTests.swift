import Testing
@testable import CodexBar

struct GroupedDailyCostTests {
    @Test func `daily sum includes estimates zero and unpriced model labels`() throws {
        let exact = GroupedDailyCost.summary(inputs: [
            .init(name: "Codex", value: .exact(3.10)),
            .init(name: "Claude", value: .exact(4.20)),
        ])
        #expect(try abs(#require(exact.totalUSD) - 7.30) < 0.000001)
        #expect(!exact.lines.joined().contains("≈"))
        let estimate = GroupedDailyCost.summary(inputs: [
            .init(name: "Codex", value: .exact(3.10)),
            .init(name: "Claude", value: .exact(4.20)),
            .init(
                name: "Grok",
                value: .estimate(0.285, unpricedModels: ["grok-9"])),
        ])
        #expect(try abs(#require(estimate.totalUSD) - 7.585) < 0.000001)
        #expect(estimate.lines.joined().contains("≈"))
        #expect(estimate.lines.joined().contains("grok-9"))
        #expect(GroupedDailyCost.summary(inputs: [.init(name: "Grok", value: .zero)]).totalUSD == 0)
    }

    @Test func `exact Grok request costs have no estimate marker`() {
        let exact = GroupedDailyCost.summary(inputs: [.init(name: "Grok", value: .exact(2.185))])
        #expect(exact.totalUSD == 2.185)
        #expect(exact.lines.joined().contains("Grok"))
        #expect(!exact.lines.joined().contains("≈"))
    }

    @Test func `loading and unpriced inputs remain visible without invented dollars`() {
        let loading = GroupedDailyCost.summary(inputs: [.init(name: "Grok", value: .loading)])
        #expect(loading.displayText == nil)
        #expect(!loading.isOverBudget(1))
        let partial = GroupedDailyCost.summary(inputs: [
            .init(name: "Codex", value: .exact(10)),
            .init(name: "Claude", value: .loading),
            .init(
                name: "Grok",
                value: .unpriced),
        ])
        #expect(partial.totalUSD == 10)
        #expect(partial.lines.joined().contains("Claude"))
        #expect(partial.lines.joined().contains("Grok"))
        #expect(!partial.isOverBudget(0))
        #expect(!partial.isOverBudget(10))
        #expect(partial.isOverBudget(9.99))
    }

    @Test func `whole currency label keeps cents in tooltip and exact total`() {
        for (usd, text, exact) in [
            (0.0, "$0.00", "$0.00"),
            (9.99, "$9.99", "$9.99"),
            (99.99, "$99.99", "$99.99"),
            (100.0, "$100", "$100.00"),
            (123.45, "$123", "$123.45"),
            (999.99, "$999", "$999.99"),
            (9999.0, "$9,999", "$9,999.00"),
            (9999.99, "$9,999", "$9,999.99"),
            (10000.0, "$10k", "$10,000.00"),
            (10999.99, "$10k", "$10,999.99"),
            (12345.67, "$12k", "$12,345.67"),
            (999_999.99, "$999k", "$999,999.99"),
        ] {
            let summary = GroupedDailyCost.summary(inputs: [.init(name: "Codex", value: .exact(usd))])
            #expect(summary.displayText == text)
            #expect(summary.totalUSD == usd)
            #expect(summary.lines.first?.contains(exact) == true)
        }
    }

    @Test func `unknown only estimates name unpriced models without invented zero dollars`() {
        let unknown = GroupedDailyCost.summary(inputs: [
            .init(name: "Grok", value: .estimate(0, unpricedModels: ["unknown-model"])),
        ])
        #expect(unknown.totalUSD == nil)
        #expect(unknown.displayText == nil)
        #expect(!unknown.lines.joined().contains("$0"))
        #expect(unknown.lines.joined().contains("unknown-model"))
        let mixed = GroupedDailyCost.summary(inputs: [
            .init(name: "Grok", value: .estimate(1.25, unpricedModels: ["unknown-model"])),
        ])
        #expect(mixed.totalUSD == 1.25)
        #expect(mixed.lines.joined().contains("$1.25"))
        #expect(mixed.lines.joined().contains("unknown-model"))
    }
}
