import Foundation

extension SettingsStore {
    var menuBarGroupsProviderIcons: Bool {
        get { self.defaultsState.menuBarGroupsProviderIcons }
        set { self.setDefault(\.menuBarGroupsProviderIcons, newValue, key: "menuBarGroupsProviderIcons") }
    }

    var menuBarGroupedPriceVisible: Bool {
        get { self.defaultsState.menuBarGroupedPriceVisible }
        set { self.setDefault(\.menuBarGroupedPriceVisible, newValue, key: "menuBarGroupedPriceVisible") }
    }

    var menuBarGroupedDailyBudgetUSD: Double {
        get {
            let value = self.defaultsState.menuBarGroupedDailyBudgetUSD
            return value.isFinite ? max(0, value) : 0
        }
        set {
            self.setDefault(
                \.menuBarGroupedDailyBudgetUSD,
                newValue.isFinite ? max(0, newValue) : 0,
                key: "menuBarGroupedDailyBudgetUSD")
        }
    }
}
