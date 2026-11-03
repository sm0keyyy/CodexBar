import CodexBarCore
import Foundation

@MainActor
struct PaceProviderTabModel {
    struct Burndown: Identifiable {
        let row: PaceWindowRow
        let samples: [PaceChartPoint]
        let remainingPercent: Double
        var id: String {
            self.row.id
        }
    }

    struct History: Identifiable {
        let id: String
        let title: String
        let role: PaceWindowRow.ColorRole
        let chart: PlanUtilizationHistoryChartMenuView.Model
    }

    struct ModelCost: Identifiable, Equatable {
        let id: String
        let title: String
        let cost: Double?
        let hasUnpricedUsage: Bool
        let share: Double?
    }

    struct Action {
        let title: String
        let action: MenuDescriptor.MenuAction
        let isEnabled: Bool
    }

    let burndowns: [Burndown]
    let histories: [History]
    let paceSummary: String?
    let isBehind: Bool
    let today: String
    let sevenDays: String
    let thirtyDays: String
    let daily: [PaceDayStack]
    let models: [ModelCost]
    let quotaWeek: InlineUsageDashboardModel.QuotaWindow?
    let actions: [Action]
    let currencyCode: String
    let preferredCurrencyCode: String
    let costIsPartial: Bool

    var showsSingleWindowStats: Bool {
        self.burndowns.count == 1
    }

    static func make(block: PaceProviderBlock, input: PacePanelInput, context: PaceProviderTabContext?) -> Self {
        let snapshot = input.costEnabled ? input.tokenSnapshots[block.provider] : nil
        let entries = CostReportingPeriod.rolling(days: 30).entries(
            snapshot?.daily ?? [], now: input.now, calendar: input.calendar)
        let currency = snapshot?.currencyCode ?? "USD"
        let partial = snapshot.map { !$0.historyIsFullyScanned } ?? false
        let paces = block.windows.compactMap(\.pace)
        let behind = paces.filter { $0.reservePercent.rounded() < 0 }.count
        let summary: String? = paces.isEmpty || paces.count != block.windows.count ? nil : (behind == 0
            ? L("pace_all_windows_ahead") : L("pace_windows_behind_format", behind))
        return Self(
            burndowns: block.windows.map { row in
                Burndown(
                    row: row,
                    samples: PacePanelModel.chartSamples(provider: block.provider, row: row, input: input),
                    remainingPercent: input.showUsed ? 100 - row.fillPercent : row.fillPercent)
            },
            histories: self.historySeries(block: block, input: input),
            paceSummary: summary,
            isBehind: behind > 0,
            today: self.todayText(block.today, currency: input.preferredCurrencyCode),
            sevenDays: self.periodCost(
                entries: CostReportingPeriod.rolling(days: 7).entries(
                    entries, now: input.now, calendar: input.calendar),
                partial: partial,
                currency: currency,
                preferred: input.preferredCurrencyCode),
            thirtyDays: self.periodCost(
                entries: entries,
                partial: partial,
                currency: currency,
                preferred: input.preferredCurrencyCode),
            daily: self.dayStacks(entries: entries, provider: block.provider, input: input),
            models: self.modelCosts(entries: entries),
            quotaWeek: snapshot.flatMap { self.currentQuotaWeek(snapshot: $0, block: block, input: input) },
            actions: self.filteredActions(context: context, provider: block.provider),
            currencyCode: currency,
            preferredCurrencyCode: input.preferredCurrencyCode,
            costIsPartial: partial)
    }

    func costText(_ cost: Double?, hasUnpricedUsage: Bool = false) -> String {
        guard let cost else { return L("pace_unpriced") }
        let value = UsageFormatter.convertedCostString(
            cost, preferredCurrency: self.preferredCurrencyCode, providerCurrency: self.currencyCode)
        let subtotal = self.costIsPartial ? L("pace_partial_cost_format", value) : value
        return hasUnpricedUsage ? L("pace_cost_with_unpriced_format", subtotal) : subtotal
    }

    private static func historySeries(block: PaceProviderBlock, input: PacePanelInput) -> [History] {
        var histories: [PlanUtilizationHistoryChartMenuView.SeriesSelection: PlanUtilizationSeriesHistory] = [:]
        for history in input.histories[block.provider] ?? [] where !history.entries.isEmpty {
            let minutes = history.name.canonicalWindowMinutes(history.windowMinutes)
            let key = PlanUtilizationHistoryChartMenuView.SeriesSelection(name: history.name, windowMinutes: minutes)
            let entries = (histories[key]?.entries ?? []) + history.entries.filter { $0.capturedAt <= input.now }
            guard !entries.isEmpty else { continue }
            histories[key] = .init(
                name: history.name,
                windowMinutes: minutes,
                entries: PlanUtilizationHistoryChartMenuView.mergedEntries(entries))
        }
        let order = block.windows.compactMap(\.series).map { $0.rawValue + ":" }
        return histories.map { key, history in
            let row = block.windows.first { $0.series == history.name && $0.pace?.durationMinutes == key.windowMinutes }
                ?? block.windows.first { $0.series == history.name }
            let title = row?.label ?? self.historyTitle(history.name, minutes: history.windowMinutes)
            return History(
                id: key.id,
                title: title,
                role: row?.role ?? .single,
                chart: PlanUtilizationHistoryChartMenuView.makeModel(
                    history: history, provider: block.provider, referenceDate: input.now))
        }.sorted { lhs, rhs in
            let left = order.firstIndex(where: { lhs.id.hasPrefix($0) }) ?? order.count
            let right = order.firstIndex(where: { rhs.id.hasPrefix($0) }) ?? order.count
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    private static func historyTitle(_ name: PlanUtilizationSeriesName, minutes: Int) -> String {
        switch name {
        case .session: L("Session")
        case .weekly: L("Weekly")
        case .monthly: L("Monthly")
        case .opus: L("pace_history_opus")
        default: L("pace_history_series_format", name.rawValue, minutes)
        }
    }

    private static func todayText(_ value: GroupedDailyCost.Value, currency: String) -> String {
        switch value {
        case let .exact(usd):
            return UsageFormatter.convertedCostString(usd, preferredCurrency: currency, providerCurrency: "USD")
        case .zero:
            return UsageFormatter.convertedCostString(0, preferredCurrency: currency, providerCurrency: "USD")
        case let .estimate(usd, models):
            if usd == 0, !models.isEmpty { return L("pace_unpriced") }
            return L("pace_estimated_cost_format", UsageFormatter.convertedCostString(
                usd, preferredCurrency: currency, providerCurrency: "USD"))
        case .unpriced: return L("pace_unpriced")
        case .loading: return L("Loading…")
        }
    }

    private static func periodCost(
        entries: [CostUsageDailyReport.Entry], partial: Bool, currency: String, preferred: String) -> String
    {
        let costs = entries.compactMap(\.costUSD)
        guard !costs.isEmpty else { return entries.isEmpty ? L("pace_not_captured") : L("pace_unpriced") }
        let value = UsageFormatter.convertedCostString(
            costs.reduce(0, +), preferredCurrency: preferred, providerCurrency: currency)
        let subtotal = partial ? L("pace_partial_cost_format", value) : value
        return entries.contains(where: self.hasUnpricedUsage)
            ? L("pace_cost_with_unpriced_format", subtotal) : subtotal
    }

    private static func hasUnpricedUsage(_ entry: CostUsageDailyReport.Entry) -> Bool {
        entry.costUSD == nil || (entry.unpricedRequestCount ?? 0) > 0
            || entry.modelBreakdowns?.contains(where: { $0.costUSD == nil }) == true
    }

    private static func dayStacks(
        entries: [CostUsageDailyReport.Entry], provider: UsageProvider, input: PacePanelInput) -> [PaceDayStack]
    {
        let today = input.calendar.startOfDay(for: input.now)
        return (-29...0).compactMap { offset in
            guard let date = input.calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let entry = CostUsageTokenSnapshot.entry(in: entries, forLocalDayContaining: date, calendar: input.calendar)
            return PaceDayStack(
                date: date,
                costsUSD: entry?.costUSD.map { [provider: $0] } ?? [:],
                unpricedProviders: entry.map { self.hasUnpricedUsage($0) ? [provider] : [] } ?? [])
        }
    }

    private static func modelCosts(entries: [CostUsageDailyReport.Entry]) -> [ModelCost] {
        var totals: [String: (cost: Double?, unpriced: Bool)] = [:]
        for entry in entries {
            let breakdowns = entry.modelBreakdowns ?? []
            for model in breakdowns {
                var total = totals[model.modelName] ?? (nil, false)
                if let cost = model.costUSD {
                    total.cost = (total.cost ?? 0) + cost
                } else {
                    total.unpriced = true
                }
                totals[model.modelName] = total
            }
            let names = Set(breakdowns.map(\.modelName))
            for name in entry.modelsUsed ?? [] where !names.contains(name) {
                var total = totals[name] ?? (nil, false)
                total.unpriced = true
                totals[name] = total
            }
        }
        let priced = totals.filter { $0.value.cost != nil }.sorted {
            let left = $0.value.cost ?? 0
            let right = $1.value.cost ?? 0
            return left == right ? $0.key < $1.key : left > right
        }
        let totalCost = entries.compactMap(\.costUSD).reduce(0, +)
        func row(id: String, title: String, cost: Double?, unpriced: Bool) -> ModelCost {
            ModelCost(
                id: id,
                title: title,
                cost: cost,
                hasUnpricedUsage: unpriced,
                share: cost.flatMap { totalCost > 0 ? $0 / totalCost : nil })
        }
        var rows = priced.prefix(3).map {
            row(
                id: $0.key,
                title: UsageFormatter.modelDisplayName($0.key),
                cost: $0.value.cost,
                unpriced: $0.value.unpriced)
        }
        if priced.count > 3 {
            let rest = priced.dropFirst(3)
            rows.append(row(
                id: "other",
                title: L("pace_all_other_models"),
                cost: rest.reduce(0) { $0 + ($1.value.cost ?? 0) },
                unpriced: rest.contains { $0.value.unpriced }))
        }
        rows += totals.filter { $0.value.cost == nil }.sorted { $0.key < $1.key }.map {
            row(id: $0.key, title: UsageFormatter.modelDisplayName($0.key), cost: nil, unpriced: true)
        }
        return rows
    }

    private static func currentQuotaWeek(
        snapshot: CostUsageTokenSnapshot, block: PaceProviderBlock, input: PacePanelInput)
        -> InlineUsageDashboardModel.QuotaWindow?
    {
        let presentation = ProviderDescriptorRegistry.descriptor(for: block.provider).presentation
        guard presentation.menuCard.showsQuotaWeekCost, let usage = input.snapshots[block.provider] else { return nil }
        let window = presentation.semanticWindows(snapshot: usage).weekly
        let observations = (input.histories[block.provider] ?? []).filter { $0.name == .weekly }
            .flatMap(\.entries).compactMap { entry -> CostUsageQuotaResetObservation? in
                entry.resetsAt.map { .init(capturedAt: entry.capturedAt, resetsAt: $0) }
            }
        let resets = usage.codexResetCredits?.credits.compactMap { $0.status == .redeemed ? $0.redeemedAt : nil } ?? []
        guard let week = snapshot.quotaWeekSummaries(
            resetAt: CostUsageTokenSnapshot.quotaWeekReset(from: window),
            windowMinutes: window?.windowMinutes,
            observedResetInstants: presentation.menuCard.ignoresObservedQuotaResetBoundaries ? [] : resets,
            resetObservations: presentation.menuCard.ignoresObservedQuotaResetBoundaries ? [] : observations,
            now: input.now,
            calendar: input.calendar).first(where: \.isCurrent) else { return nil }
        let cost = week.totalCostUSD.map {
            UsageFormatter.convertedCostString(
                $0, preferredCurrency: input.preferredCurrencyCode, providerCurrency: snapshot.currencyCode)
        }
        let row = UsageMenuCardView.Model.quotaWindowRow(
            week: week, cost: cost ?? "—", calendar: input.calendar)
        guard let tokens = week.totalTokens else { return row }
        return InlineUsageDashboardModel.QuotaWindow(
            id: row.id,
            title: row.title,
            range: row.range,
            value: L(
                "pace_weekly_cost_tokens_format",
                UsageMenuCardView.Model.quotaMetricValue(cost, complete: week.costIsComplete),
                UsageMenuCardView.Model.quotaMetricValue(
                    UsageFormatter.tokenCountString(tokens), complete: week.tokensAreComplete)),
            note: row.note)
    }

    private static func filteredActions(context: PaceProviderTabContext?, provider: UsageProvider) -> [Action] {
        guard let context else { return [] }
        func allowed(_ action: MenuDescriptor.MenuAction) -> Bool {
            switch action {
            case .statusPage, .changelog, .focusAgentSession, .refresh, .settings, .about, .quit:
                false
            case .addProviderAccount, .switchAccount, .addCodexAccount, .requestCodexSystemPromotion,
                 .loginToProvider, .openTerminal:
                context.error != nil || context.accountCount > 1
            default: true
            }
        }
        var rows: [Action] = []
        for entry in context.menu.sections.flatMap(\.entries) {
            switch entry {
            case let .action(title, action) where allowed(action):
                rows.append(Action(title: title, action: action, isEnabled: true))
            case let .submenu(_, _, items):
                rows += items.compactMap { item in
                    guard let action = item.action, allowed(action) else { return nil }
                    return Action(title: item.title, action: action, isEnabled: item.isEnabled)
                }
            default: break
            }
        }
        if let error = context.error {
            if !rows.contains(where: { row in
                switch row.action {
                case .switchAccount, .addProviderAccount, .addCodexAccount, .loginToProvider,
                     .openTerminal, .providerSettings: true
                default: false
                }
            }) {
                rows.append(Action(title: L("pace_login"), action: .switchAccount(provider), isEnabled: true))
            }
            if !rows.contains(where: {
                if case .copyError = $0.action {
                    true
                } else {
                    false
                }
            }) {
                rows.append(Action(title: L("Copy error"), action: .copyError(error), isEnabled: true))
            }
        }
        return rows
    }
}
