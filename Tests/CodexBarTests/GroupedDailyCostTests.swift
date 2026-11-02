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
}
