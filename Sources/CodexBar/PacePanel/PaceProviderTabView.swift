import CodexBarCore
import SwiftUI

struct PaceProviderTabContext {
    let card: UsageMenuCardView.Model?
    let menu: MenuDescriptor
    let accountCount: Int
    let error: String?

    @MainActor
    static func accountCount(
        menu: MenuDescriptor,
        managed: @autoclosure () -> Int,
        tokens: @autoclosure () -> Int) -> Int
    {
        for section in menu.sections {
            for entry in section.entries {
                if case .action(_, .addCodexAccount) = entry { return managed() }
            }
        }
        return tokens()
    }
}

struct PaceProviderTabView: View {
    let block: PaceProviderBlock
    let input: PacePanelInput
    let context: PaceProviderTabContext?
    let onAction: (MenuDescriptor.MenuAction) -> Void

    var body: some View {
        let model = PaceProviderTabModel.make(block: self.block, input: self.input, context: self.context)
        VStack(alignment: .leading, spacing: 8) {
            self.header(model)
            self.planUsage(model)
            PaceProviderHistoryView(histories: model.histories, provider: self.block.provider)
            Divider()
            self.costs(model)
            self.creditRows
            if !model.actions.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(model.actions.indices, id: \.self) { index in
                        let row = model.actions[index]
                        Button { self.onAction(row.action) } label: {
                            HStack {
                                Text(row.title)
                                Spacer(minLength: 0)
                                if row.action == .dashboard {
                                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!row.isEnabled)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .monospacedDigit()
    }

    private func header(_ model: PaceProviderTabModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.block.name).fontWeight(.semibold)
                if let plan = self.context?.card?.planText {
                    Text(plan).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let email = self.context?.card?.email, !email.isEmpty {
                    Text(email).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).help(email)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Text(self.context?.card?.subtitleText ?? self.updatedText)
                    .foregroundStyle(self.context?.error == nil ? Color.secondary : Color(nsColor: .systemOrange))
                Spacer(minLength: 0)
                if let summary = model.paceSummary {
                    Text(summary).multilineTextAlignment(.trailing)
                        .foregroundStyle(model.isBehind ? Color(nsColor: .systemOrange) : .secondary)
                }
            }
            .font(.system(size: 10))
            if let error = self.context?.error, error != self.context?.card?.subtitleText {
                Text(error).font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))
                    .textSelection(.enabled)
            }
        }
    }

    private var updatedText: String {
        self.input.snapshots[self.block.provider].map {
            UsageFormatter.updatedString(from: $0.updatedAt, now: self.input.now)
        } ?? L("No usage yet")
    }

    private func planUsage(_ model: PaceProviderTabModel) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("Plan Usage")).fontWeight(.semibold)
                Spacer(minLength: 0)
                Text(L("pace_remaining_vs_ideal")).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if model.burndowns.isEmpty {
                Text(L("No usage yet")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else if let burn = model.burndowns.first, model.showsSingleWindowStats {
                self.burndown(burn, small: false)
                self.stats(burn)
            } else {
                LazyVGrid(columns: Array(
                    repeating: GridItem(.flexible(), spacing: 10),
                    count: min(3, model.burndowns.count)), spacing: 10)
                {
                    ForEach(model.burndowns) { self.burndown($0, small: true) }
                }
            }
            Text(self.context?.card?.lastKnownUsageText ?? L("pace_last_capture_format", self.updatedText))
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Text(L("pace_burndown_legend")).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func burndown(_ burn: PaceProviderTabModel.Burndown, small: Bool) -> some View {
        let color = PacePalette.colors(for: self.block.provider, role: burn.row.role).fill
        let summary = burn.samples.last.map {
            L(
                "pace_chart_point_format",
                self.block.name + " " + burn.row.label,
                burn.remainingPercent,
                $0.x * 100)
        } ?? L("pace_row_remaining_format", self.block.name, burn.row.label, burn.remainingPercent)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(burn.row.label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(self.percent(burn.remainingPercent)).fontWeight(.semibold)
            }
            .font(.system(size: 11))
            if burn.samples.isEmpty {
                Text(L("No data")).font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: small ? 64 : 96)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 3))
            } else {
                PaceBurndownChart(
                    provider: self.block.provider,
                    samples: burn.samples,
                    color: color,
                    accessibilitySummary: summary,
                    showsAxes: !small)
                    .frame(height: small ? 64 : 96)
                    .background(Color.primary.opacity(small ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 3))
            }
            if small {
                Text(burn.row.countdown ?? "—").foregroundStyle(.secondary)
                if let pace = burn.row.pace {
                    Text(WindowPace.paceText(reservePercent: pace.reservePercent))
                        .foregroundStyle(pace.reservePercent.rounded() < 0 ? Color(nsColor: .systemOrange) : .secondary)
                }
            }
        }
        .font(.system(size: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            summary,
            burn.row.pace.map { WindowPace.paceText(reservePercent: $0.reservePercent) },
            burn.row.countdown.map { L("pace_resets_in_format", $0) },
        ]
            .compactMap(\.self).joined(separator: ". "))
    }

    private func stats(_ burn: PaceProviderTabModel.Burndown) -> some View {
        HStack(alignment: .top, spacing: 6) {
            self.stat(L("Remaining"), value: self.percent(burn.remainingPercent))
            self.stat(L("pace_ideal_now"), value: burn.row.pace.map { self.percent($0.idealRemainingPercent) } ?? "—")
            self.stat(
                L("pace_reserve"),
                value: burn.row.pace.map {
                    ($0.reservePercent.rounded() < 0 ? "−" : "+") + self.percent(abs($0.reservePercent.rounded()))
                } ?? "—",
                warning: burn.row.pace?.reservePercent.rounded() ?? 0 < 0)
            self.stat(L("pace_resets"), value: burn.row.countdown ?? "—")
        }
    }

    private func stat(_ title: String, value: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(warning ? Color(nsColor: .systemOrange) : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func costs(_ model: PaceProviderTabModel) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                PaceProviderCostStat(title: L("Today"), amount: model.today, caption: nil)
                PaceProviderCostStat(
                    title: L("7 days"),
                    amount: model.sevenDays.amount,
                    caption: model.sevenDays.caption)
                PaceProviderCostStat(
                    title: L("pace_thirty_days"), amount: model.thirtyDays.amount, caption: model.thirtyDays.caption)
            }
            if let week = model.quotaWeek {
                PaceKeyValueRow(title: L("pace_current_weekly_window"), value: week.value)
                    .help([week.range, week.note].compactMap(\.self).joined(separator: ". "))
            }
            HStack {
                Text(L("pace_thirty_day_cost_chart"))
                Spacer(minLength: 0)
                // Provider-specific by design: Grok prices native and mirror usage at official xAI tariffs.
                if self.block.provider == .grok { Text(L("pace_official_xai_rates")) }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            PaceDailyBars(
                days: model.daily,
                providers: [self.block.provider],
                preferredCurrencyCode: self.input.preferredCurrencyCode,
                providerCurrencyCode: model.currencyCode)
                .frame(height: 56)
            if model.costIsPartial {
                Text(L("Partial estimate")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            self.modelTable(model)
        }
    }

    private func modelTable(_ model: PaceProviderTabModel) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                Text(L("pace_models_thirty_days"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Cost"))
                Text(L("pace_model_share"))
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(model.models) { row in
                GridRow {
                    Text(row.title).lineLimit(1).help(row.title)
                    Text(model.costText(row.cost, hasUnpricedUsage: row.hasUnpricedUsage))
                        .multilineTextAlignment(.trailing)
                    Text(row.share.map { ($0 * 100).formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                }
                .font(.system(size: 10))
                .accessibilityElement(children: .combine)
            }
            if model.models.isEmpty {
                Text(L("pace_not_captured")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var creditRows: some View {
        if let card = self.context?.card {
            VStack(alignment: .leading, spacing: 4) {
                if let credits = card.limitResetCredits {
                    LimitResetCreditsContent(presentation: credits)
                }
                if let credits = card.creditsText {
                    PaceKeyValueRow(title: L("Credits"), value: credits)
                    if let hint = card.creditsHintText {
                        Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                ForEach(
                    Array([card.cloudCredits, card.providerCost].compactMap(\.self).enumerated()),
                    id: \.offset)
                { _, section in
                    PaceKeyValueRow(title: section.title, value: section.spendLine)
                    ForEach([
                        section.percentLine,
                        section.balanceLine,
                        section.personalSpendLine,
                        section.dailyTargetText,
                    ].compactMap(\.self), id: \.self) { text in
                        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(card.providerDetails.enumerated()), id: \.offset) { _, section in
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        PaceKeyValueRow(
                            title: row.label,
                            value: [row.value, row.secondaryValue].compactMap(\.self)
                                .joined(separator: " · "))
                    }
                }
            }
        }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "%"
    }
}

struct PaceProviderCostStat: View {
    let title: String
    let amount: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(self.amount)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if let caption = self.caption {
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct PaceProviderHistoryView: View {
    let histories: [PaceProviderTabModel.History]
    let provider: UsageProvider
    @State private var selection: String?
    @State private var pointIndex: Int?

    var body: some View {
        let history = self.histories.first(where: { $0.id == self.selection })
            ?? self.histories.first(where: { $0.id.hasPrefix("weekly:") }) ?? self.histories.first
        VStack(alignment: .leading, spacing: 5) {
            Text(L("pace_history_used")).font(.system(size: 9)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(self.histories) { series in
                        PaceChip(title: series.title, isSelected: series.id == history?.id) {
                            self.selection = series.id
                            self.pointIndex = nil
                        }
                    }
                }
            }
            if let history, !history.chart.points.isEmpty {
                self.chart(history)
                let point = self.pointIndex.flatMap { history.chart.pointsByIndex[$0] }
                    ?? history.chart.points.last
                if let point {
                    PaceKeyValueRow(
                        title: point.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()
                            .locale(codexBarLocalizedLocale())),
                        value: point.isObserved ? L("pace_history_used_format", point.usedPercent) : "—")
                }
            } else {
                Text(L("pace_history_empty"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
        }
    }

    private func chart(_ history: PaceProviderTabModel.History) -> some View {
        let colors = PacePalette.colors(for: self.provider, role: history.role)
        let points = history.chart.points
        return GeometryReader { geometry in
            let height = geometry.size.height - 14
            let step = geometry.size.width / 30
            ZStack(alignment: .topLeading) {
                Path { path in
                    for point in points {
                        path.addRoundedRect(in: CGRect(
                            x: step * (Double(point.index) + 0.5) - 3,
                            y: 0,
                            width: 6,
                            height: height), cornerSize: CGSize(
                            width: 2,
                            height: 2))
                    }
                }.fill(colors.track)
                Path { path in
                    for point in points where point.isObserved {
                        path.addRect(CGRect(
                            x: step * (Double(point.index) + 0.5) - 3,
                            y: height * (1 - point.usedPercent / 100),
                            width: 6,
                            height: height * point.usedPercent / 100))
                    }
                }.fill(colors.fill)
                ForEach(history.chart.axisIndexes, id: \.self) { index in
                    if let point = history.chart.pointsByIndex[Int(index)] {
                        Text(point.date
                            .formatted(.dateTime.month(.abbreviated).day().locale(codexBarLocalizedLocale())))
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                            .fixedSize().position(x: max(18, step * (index + 0.5)), y: height + 9)
                    }
                }
                if let index = self.pointIndex {
                    Path { path in
                        let x = step * (Double(index) + 0.5)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: height))
                    }.stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    let index = Int(location.x / step)
                    self.pointIndex = history.chart.pointsByIndex[index] == nil ? nil : index
                case .ended: self.pointIndex = nil
                }
            }
        }
        .frame(height: 52)
        .focusable()
        .onKeyPress(.upArrow) {
            self.pointIndex = max(0, (self.pointIndex ?? points.count) - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            self.pointIndex = min(points.count - 1, (self.pointIndex ?? -1) + 1)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(
            "pace_history_chart_format",
            history.title,
            points.filter(\.isObserved).map { point in
                L(
                    "pace_history_point_format",
                    point.date
                        .formatted(.dateTime.month(.abbreviated).day().locale(codexBarLocalizedLocale())),
                    point.usedPercent)
            }.joined(separator: ". ")))
    }
}
