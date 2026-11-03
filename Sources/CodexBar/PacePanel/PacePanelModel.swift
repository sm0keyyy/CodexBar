import CodexBarCore
import Foundation

struct PaceWindowRow: Equatable, Identifiable {
    enum ColorRole: Hashable {
        case single, session, weekly
    }

    let id: String
    let label: String
    let fillPercent: Double
    let pace: WindowPace?
    let tickPercent: Double?
    let countdown: String?
    let role: ColorRole
    let series: PlanUtilizationSeriesName?
}

struct PaceProviderBlock: Equatable {
    let provider: UsageProvider
    let name: String
    let today: GroupedDailyCost.Value
    let windows: [PaceWindowRow]
}

struct PaceChartPoint: Equatable {
    let x: Double
    let remainingPercent: Double
}

struct PaceChartSeries: Equatable {
    let provider: UsageProvider
    let samples: [PaceChartPoint]
    let label: String
}

struct PaceDayStack: Equatable, Identifiable {
    let date: Date
    let costsUSD: [UsageProvider: Double]
    let unpricedProviders: Set<UsageProvider>

    var id: Date {
        self.date
    }

    var totalUSD: Double? {
        self.costsUSD.isEmpty ? nil : self.costsUSD.values.reduce(0, +)
    }
}

struct PacePanelModel: Equatable {
    let providers: [PaceProviderBlock]
    let today: GroupedDailyCost.Summary
    let sessionSeries: [PaceChartSeries]
    let weeklySeries: [PaceChartSeries]
    let last7Days: [PaceDayStack]
    let showUsed: Bool

    static func make(_ input: PacePanelInput) -> PacePanelModel {
        let providers = input.providers.map { provider in
            let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            return PaceProviderBlock(
                provider: provider,
                name: name,
                today: input.todayCostInputs.first(where: { $0.name == name })?.value ?? .loading,
                windows: self.windowRows(provider: provider, input: input))
        }
        func series(for windowClass: WindowPace.WindowClass) -> [PaceChartSeries] {
            providers.compactMap { block in
                guard let row = block.windows.first(where: { $0.pace?.windowClass == windowClass }) else {
                    return nil
                }
                return PaceChartSeries(
                    provider: block.provider,
                    samples: self.chartSamples(provider: block.provider, row: row, input: input),
                    label: block.name)
            }
        }
        return PacePanelModel(
            providers: providers,
            today: GroupedDailyCost.summary(
                inputs: input.todayCostInputs, preferredCurrency: input.preferredCurrencyCode),
            sessionSeries: series(for: .session),
            weeklySeries: series(for: .weekly),
            last7Days: self.dayStacks(input),
            showUsed: input.showUsed)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.providers == rhs.providers
            && lhs.today.totalUSD == rhs.today.totalUSD
            && lhs.today.displayText == rhs.today.displayText
            && lhs.today.lines == rhs.today.lines
            && lhs.sessionSeries == rhs.sessionSeries
            && lhs.weeklySeries == rhs.weeklySeries
            && lhs.last7Days == rhs.last7Days
            && lhs.showUsed == rhs.showUsed
    }

    static func chartSamples(provider: UsageProvider, row: PaceWindowRow, input: PacePanelInput) -> [PaceChartPoint] {
        guard let snapshot = input.snapshots[provider], snapshot.updatedAt <= input.now, let pace = row.pace
        else { return [] }
        let window: RateWindow? = switch row.id {
        case "primary": snapshot.primary
        case "secondary": snapshot.secondary
        case "tertiary": snapshot.tertiary
        default: snapshot.extraRateWindows?.first(where: { $0.id == row.id })?.window
        }
        guard let window, let reset = window.resetsAt else { return [] }
        let name = row.series ?? .session
        let historyMinutes: Int = switch row.id {
        case "primary", "secondary", "tertiary": pace.durationMinutes
        default: window.windowMinutes ?? pace.durationMinutes
        }
        let history = input.histories[provider]?.first {
            $0.name == name && $0.windowMinutes == name.canonicalWindowMinutes(historyMinutes)
        } ?? PlanUtilizationSeriesHistory(name: name, windowMinutes: historyMinutes, entries: [])
        let resolvedWindow = RateWindow(
            usedPercent: window.usedPercent,
            windowMinutes: pace.durationMinutes,
            resetsAt: reset,
            resetDescription: window.resetDescription)
        guard let model = QuotaBurndownModel(history: history, window: resolvedWindow, now: snapshot.updatedAt)
        else { return [] }
        let duration = model.reset.timeIntervalSince(model.start)
        return model.samples.map {
            PaceChartPoint(x: $0.date.timeIntervalSince(model.start) / duration, remainingPercent: $0.remainingPercent)
        }
    }

    private static func windowRows(provider: UsageProvider, input: PacePanelInput) -> [PaceWindowRow] {
        guard let snapshot = input.snapshots[provider] else { return [] }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let labels = descriptor.presentation.rateWindowLabels(
            metadata: descriptor.metadata, snapshot: snapshot, now: input.now)
        var windows: [(id: String, label: String, window: RateWindow)] = []
        for (id, label, window) in [
            ("primary", labels.primary, snapshot.primary),
            ("secondary", labels.secondary, snapshot.secondary),
            ("tertiary", labels.tertiary, snapshot.tertiary),
        ] {
            if let window, !window.isSyntheticPlaceholder, window.usedPercent.isFinite {
                windows.append((id, label, window))
            }
        }
        for extra in snapshot.extraRateWindows ?? [] where extra.usageKnown {
            if !extra.window.isSyntheticPlaceholder, extra.window.usedPercent.isFinite {
                windows.append((extra.id, extra.title, extra.window))
            }
        }
        return windows.map { entry in
            let pace = WindowPace.make(window: entry.window, provider: provider, now: input.now)
            let duration = WindowPace.durationMinutes(window: entry.window, provider: provider, now: input.now)
            let role: PaceWindowRow.ColorRole = windows.count == 1 ? .single
                : (duration.map { $0 <= 1440 } ?? (entry.id == "primary") ? .session : .weekly)
            return PaceWindowRow(
                id: entry.id,
                label: L(entry.label),
                fillPercent: UsagePercent(raw: input.showUsed ? entry.window.usedPercent : 100 - entry.window
                    .usedPercent)
                    .displayClamped,
                pace: pace,
                tickPercent: pace?.tickPercent(showUsed: input.showUsed),
                countdown: entry.window.resetsAt
                    .map { UsageFormatter.resetCountdownDuration(from: $0, now: input.now) },
                role: role,
                series: PaceHistorySeries.name(
                    provider: provider, windowID: entry.id, window: entry.window, now: input.now))
        }
    }

    private static func dayStacks(_ input: PacePanelInput) -> [PaceDayStack] {
        let today = input.calendar.startOfDay(for: input.now)
        return (-6...0).compactMap { offset in
            guard let day = input.calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            var costs: [UsageProvider: Double] = [:]
            var unpriced: Set<UsageProvider> = []
            if input.costEnabled {
                for provider in input.providers {
                    guard let snapshot = input.tokenSnapshots[provider], snapshot.currencyCode == "USD",
                          let entry = CostUsageTokenSnapshot.entry(
                              in: snapshot.daily, forLocalDayContaining: day, calendar: input.calendar)
                    else { continue }
                    if let cost = entry.costUSD, cost.isFinite, cost >= 0 { costs[provider] = cost }
                    if entry.costUSD == nil || entry.modelBreakdowns?.contains(where: { $0.costUSD == nil }) == true {
                        unpriced.insert(provider)
                    }
                }
            }
            return PaceDayStack(date: day, costsUSD: costs, unpricedProviders: unpriced)
        }
    }
}
