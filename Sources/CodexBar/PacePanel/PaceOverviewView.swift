import CodexBarCore
import SwiftUI

struct PaceOverviewView: View {
    let model: PacePanelModel
    let input: PacePanelInput
    let onAction: (MenuDescriptor.MenuAction) -> Void
    var onFix: (UsageProvider, GroupedPillState.Fix) -> Void = { _, _ in }
    @State var showsWeekly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !self.model.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(self.model.warnings, id: \.provider) { block in
                        if let reason = block.stateReason {
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(PacePalette.colors(for: block.provider).fill)
                                    .frame(width: 7, height: 7).padding(.top, 3)
                                Text(reason.text).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let fix = reason.fix {
                                    Button(fix.title) { self.onFix(block.provider, fix) }
                                        .controlSize(.mini)
                                }
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                }
                .font(.system(size: 11))
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            HStack {
                Text(L("pace_every_provider")).fontWeight(.semibold)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    PaceChip(title: L("Session"), isSelected: !self.showsWeekly) { self.showsWeekly = false }
                    PaceChip(title: L("Weekly"), isSelected: self.showsWeekly) { self.showsWeekly = true }
                }
                .padding(2)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("pace_window_class"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)

            PaceSharedChart(
                series: self.chartSeries,
                windowClass: self.showsWeekly ? .weekly : .session,
                providers: self.model.providers)
                .padding(.horizontal, 16)
            Text(L(self.chartSeries.isEmpty ? "pace_no_windows" : "pace_chart_guidance"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            Divider().padding(.vertical, 6)
            self.timelineLegend
            ForEach(self.model.providers, id: \.provider) { block in
                self.providerHeader(block)
                ForEach(block.windows) { row in
                    PaceTimelineRow(
                        provider: block.provider,
                        row: row,
                        showUsed: self.model.showUsed,
                        stateReason: block.stateReason)
                }
            }
            Divider().padding(.top, 8)
            if self.input.costEnabled {
                self.todaySection
                self.dailySection
            } else {
                Text(L("grouped_icons_cost_off_hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
    }

    var chartSeries: [PaceChartSeries] {
        self.showsWeekly ? self.model.weeklySeries : self.model.sessionSeries
    }

    var todayTotalUSD: Double? {
        if self.input.isReloading, let retained = self.input.retainedTodayTotalUSD { return retained }
        return self.model.today.totalUSD
    }

    var isTodayTotalDimmed: Bool {
        self.input.isReloading && self.input.retainedTodayTotalUSD != nil
    }

    var todayTotalText: String {
        if let total = self.todayTotalUSD { return self.formatCost(total) }
        return L(self.model.providers.contains { $0.today == .loading }
            ? "grouped_icons_tooltip_loading" : "pace_unpriced")
    }

    private var timelineLegend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Rectangle().fill(.primary).frame(width: 1.5, height: 9)
                Text(L("pace_tick_legend"))
            }
            Text(L(self.model.showUsed ? "pace_fill_used" : "pace_fill_remaining"))
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
    }

    private func providerHeader(_ block: PaceProviderBlock) -> some View {
        HStack(spacing: 6) {
            Circle().fill(PacePalette.colors(for: block.provider).fill).frame(width: 7, height: 7)
            Text(block.name).fontWeight(.semibold)
            Spacer(minLength: 4)
            if self.input.costEnabled {
                Text(L("Today")).foregroundStyle(.secondary)
                Text(self.costText(for: block.today)).fontWeight(.semibold)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .accessibilityElement(children: .combine)
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(L("Today")).foregroundStyle(.secondary)
                Text(self.todayTotalText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(self.todayTotalUSD.map { self.input.dailyBudgetUSD > 0
                            && $0 > self.input.dailyBudgetUSD
                    } == true ? Color(nsColor: .systemOrange) : .primary)
                    .opacity(self.isTodayTotalDimmed ? 0.55 : 1)
            }
            .accessibilityElement(children: .combine)
            PaceStackedBar(segments: self.model.providers.compactMap { block in
                block.today.usd.map { PaceCostSegment(provider: block.provider, usd: $0) }
            })
            HStack(alignment: .top, spacing: 10) {
                ForEach(self.model.providers, id: \.provider) { block in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.name).foregroundStyle(.secondary)
                        Text(self.costText(for: block.today)).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(size: 11))
        }
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("pace_seven_day_cost"))
                Spacer(minLength: 4)
                Text(L("pace_stacked_by_provider"))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            PaceDailyBars(
                days: self.model.last7Days,
                providers: self.model.providers.map(\.provider),
                preferredCurrencyCode: self.input.preferredCurrencyCode)
                .frame(height: 52)
            if self.model.last7Days.allSatisfy({ $0.totalUSD == nil }) {
                Text(L("pace_no_cost_history")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if self.model.last7Days.contains(where: { !$0.unpricedProviders.isEmpty }) {
                Text(L("pace_unpriced")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    func costText(for value: GroupedDailyCost.Value) -> String {
        switch value {
        case let .exact(usd): return self.formatCost(usd)
        case .zero: return self.formatCost(0)
        case .loading: return L("grouped_icons_tooltip_loading")
        case .unpriced: return L("pace_unpriced")
        case let .estimate(usd, models):
            if usd == 0, !models.isEmpty { return L("pace_unpriced") }
            return "≈" + self.formatCost(usd)
        }
    }

    private func formatCost(_ usd: Double) -> String {
        UsageFormatter.convertedCostString(
            usd, preferredCurrency: self.input.preferredCurrencyCode, providerCurrency: "USD")
    }
}
