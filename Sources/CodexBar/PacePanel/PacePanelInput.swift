import CodexBarCore
import Foundation

struct PacePanelInput {
    let providers: [UsageProvider]
    var snapshots: [UsageProvider: UsageSnapshot] = [:]
    var histories: [UsageProvider: [PlanUtilizationSeriesHistory]] = [:]
    var tokenSnapshots: [UsageProvider: CostUsageTokenSnapshot] = [:]
    var pillStates: [UsageProvider: GroupedPillState] = [:]
    var todayCostInputs: [GroupedDailyCost.ProviderCostInput] = []
    var showUsed = false
    var costEnabled = true
    var preferredCurrencyCode = "USD"
    var dailyBudgetUSD: Double = 0
    var isReloading = false
    var retainedTodayTotalUSD: Double?
    let now: Date
    var calendar: Calendar = .current
}
