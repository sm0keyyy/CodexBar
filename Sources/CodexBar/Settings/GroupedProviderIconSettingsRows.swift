import CodexBarCore
import SwiftUI

struct GroupedProviderIconSettingsRows: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Toggle(isOn: self.$settings.menuBarGroupsProviderIcons) {
            SettingsRowLabel(L("grouped_icons_title"), subtitle: L("grouped_icons_subtitle"))
        }
        .disabled(!self.settings.mergeIcons)

        if !self.settings.costUsageEnabled {
            Text(L("grouped_icons_cost_off_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        HStack {
            SettingsRowLabel(L("grouped_icons_budget_title"), subtitle: L("grouped_icons_budget_subtitle"))
            TextField(
                L("grouped_icons_budget_title"),
                value: Binding<Double?>(
                    get: {
                        self.settings.menuBarGroupedDailyBudgetUSD > 0 ? self.settings
                            .menuBarGroupedDailyBudgetUSD : nil
                    },
                    set: { self.settings.menuBarGroupedDailyBudgetUSD = $0 ?? 0 }),
                format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .accessibilityLabel(L("grouped_icons_budget_title"))
        }
        .disabled(!self.settings.mergeIcons || !self.settings.menuBarGroupsProviderIcons)
    }
}
