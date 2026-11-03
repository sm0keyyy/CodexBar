import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PaceProviderTabModelTests {
    @Test func `T22 single account keeps dashboard and removes excluded actions`() throws {
        let input = Self.fixture()
        let context = Self.context(provider: .claude, input: input)
        let model = try self.model(.claude, input: input, context: context)
        #expect(model.actions.map(\.action) == [.dashboard])
        #expect(model.actions.map(\.title) == ["Usage Dashboard"])
    }

    @Test func `T22b error restores login and Copy Error without removed rows`() throws {
        let input = Self.fixture()
        let model = try self.model(
            .claude,
            input: input,
            context: Self.context(
                provider: .claude,
                input: input,
                error: "Fixture login failed"))
        #expect(model.actions.map(\.action) == [
            .dashboard,
            .addProviderAccount(.claude),
            .switchAccount(.claude),
            .addCodexAccount,
            .copyError("Fixture login failed"),
        ])
        let supplied = PaceProviderTabContext(
            card: nil,
            menu: .init(sections: [.init(entries: [
                .action("Login", .loginToProvider(url: "https://example.test/login")),
                .action("Copy Error", .copyError("Fixture login failed")),
            ])]),
            accountCount: 1,
            error: "Fixture login failed")
        let actions = try self.model(.claude, input: input, context: supplied).actions
        #expect(actions.count == 2)
        let missing = PaceProviderTabContext(
            card: nil, menu: .init(sections: []), accountCount: 1, error: "Fixture login failed")
        #expect(try self.model(.claude, input: input, context: missing).actions.map(\.action) == [
            .switchAccount(.claude), .copyError("Fixture login failed"),
        ])
    }

    @Test func `T23 model table keeps three priced models then the remainder and unpriced names`() throws {
        var input = Self.fixture()
        input.tokenSnapshots[.grok] = Self.costSnapshot(now: input.now, daily: [Self.entry(
            date: "2026-11-02", cost: 150, models: [
                .init(modelName: "fixture-a", costUSD: 50), .init(modelName: "fixture-b", costUSD: 40),
                .init(modelName: "fixture-c", costUSD: 30), .init(modelName: "fixture-d", costUSD: 20),
                .init(modelName: "fixture-e", costUSD: 10), .init(modelName: "fixture-unknown", costUSD: nil),
            ])])
        let model = try self.model(.grok, input: input)
        #expect(model.models.map(\.id) == ["fixture-a", "fixture-b", "fixture-c", "other", "fixture-unknown"])
        #expect(model.models.map(\.cost) == [50, 40, 30, 30, nil])
        #expect(model.models[3].title == "all other models")
        #expect(model.models[3].share == 0.2)
        #expect(model.costText(model.models[4].cost) == "unpriced")
        #expect(model.thirtyDays == "$150.00 · unpriced")
        let entries = try #require(input.tokenSnapshots[.grok]?.daily)
        input.tokenSnapshots[.grok] = Self.costSnapshot(
            now: input.now, daily: entries + [Self.entry(date: "2026-11-01", cost: 50)])
        #expect(try self.model(.grok, input: input).models.first?.share == 0.25)
    }

    @Test func `T24 Grok uses one burndown with stats and Claude uses three small multiples`() throws {
        let input = Self.fixture()
        let grok = try self.model(.grok, input: input)
        #expect(grok.burndowns.count == 1)
        #expect(grok.showsSingleWindowStats)
        #expect(grok.burndowns.first?.remainingPercent == 95)
        #expect(grok.burndowns.first?.samples.count == 3)
        #expect(grok.burndowns.first?.samples.first?.x != 0)
        let claude = try self.model(.claude, input: input)
        #expect(claude.burndowns.map(\.row.label) == ["Session", "Weekly", "Fable"])
        #expect(!claude.showsSingleWindowStats)
        #expect(claude.burndowns.map(\.remainingPercent) == [94, 58, 96])
        #expect(claude.histories.map(\.title) == ["Session", "Weekly", "Fable"])
        var used = input
        used.showUsed = true
        #expect(try self.model(.claude, input: used).burndowns.map(\.remainingPercent) == [94, 58, 96])
    }

    @Test func `history retains extra and odd series and plots peaks per reset period`() throws {
        var input = Self.fixture()
        let reset = try #require(input.snapshots[.grok]?.primary?.resetsAt)
        input.histories[.grok] = [.init(name: .weekly, windowMinutes: 10500, entries: [
            .init(capturedAt: input.now.addingTimeInterval(-7200), usedPercent: 12, resetsAt: reset),
            .init(capturedAt: input.now.addingTimeInterval(-3600), usedPercent: 5, resetsAt: reset),
        ])]
        let model = try self.model(.grok, input: input)
        #expect(model.histories.first?.id == "weekly:10500")
        #expect(model.histories.first?.chart.points.filter(\.isObserved).map(\.usedPercent) == [12])
        input.histories[.grok] = []
        #expect(try self.model(.grok, input: input).histories.isEmpty)
    }

    @Test func `cost periods use local days and preserve missing and partially priced usage`() throws {
        var input = Self.fixture()
        input.tokenSnapshots[.grok] = Self.costSnapshot(now: input.now, daily: [
            Self.entry(date: "2026-11-02", cost: 7.96),
            Self.entry(date: "2026-11-01", cost: 10),
            Self.entry(date: "2026-10-25", cost: 20),
            Self.entry(date: "2026-10-03", cost: 1000),
        ])
        let model = try self.model(.grok, input: input)
        #expect(model.today == "$7.96")
        #expect(model.sevenDays == "$17.96")
        #expect(model.thirtyDays == "$37.96")
        #expect(model.daily.count == 30)
        #expect(model.daily.compactMap(\.totalUSD).reduce(0, +) == 37.96)
        #expect(model.daily[1].totalUSD == nil)
        input.costEnabled = false
        let disabled = try self.model(.grok, input: input)
        #expect(disabled.models.isEmpty)
        #expect(disabled.thirtyDays == "not captured")
        #expect(disabled.daily.allSatisfy { $0.totalUSD == nil })
    }

    @Test func `mixed model pricing retains the known subtotal and the unpriced marker`() throws {
        var input = Self.fixture()
        input.tokenSnapshots[.grok] = Self.costSnapshot(now: input.now, daily: [
            Self.entry(date: "2026-11-01", cost: 2, models: [.init(modelName: "fixture-mixed", costUSD: 2)]),
            Self.entry(date: "2026-11-02", cost: nil, models: [.init(modelName: "fixture-mixed", costUSD: nil)]),
        ])
        let model = try self.model(.grok, input: input)
        let row = try #require(model.models.first)
        #expect(row.hasUnpricedUsage)
        #expect(model.costText(row.cost, hasUnpricedUsage: row.hasUnpricedUsage) == "$2.00 · unpriced")
        #expect(model.daily.last?.unpricedProviders == [.grok])
        #expect(model.daily.last?.totalUSD == nil)
    }

    @Test func `weekly quota cost follows the current reset and missing snapshots stay empty`() throws {
        let input = Self.fixture()
        let claude = try self.model(.claude, input: input)
        #expect(claude.quotaWeek?.value == "$85.11 · 4K")
        #expect(try self.model(.grok, input: input).quotaWeek == nil)
        var empty = input
        empty.snapshots[.grok] = nil
        empty.histories[.grok] = []
        let missing = try self.model(.grok, input: empty)
        #expect(missing.burndowns.isEmpty)
        #expect(missing.histories.isEmpty)
        #expect(!missing.showsSingleWindowStats)
        #expect(missing.paceSummary == nil)
    }

    @Test func `provider model text never exposes the forbidden name`() throws {
        let model = try self.model(.claude, input: Self.fixture())
        let texts = [model.today, model.sevenDays, model.thirtyDays, model.paceSummary ?? ""]
            + model.models.map(\.title) + model.histories.map(\.title) + model.actions.map(\.title)
        #expect(texts.allSatisfy { !$0.localizedCaseInsensitiveContains("Code" + "Burn") })
    }

    @Test func `today keeps tariff estimates distinct from exact zero and unpriced usage`() throws {
        var input = Self.fixture()
        for (value, expected) in [
            (GroupedDailyCost.Value.estimate(7.96, unpricedModels: ["fixture-unknown"]), "≈$7.96 (estimate)"),
            (.estimate(0, unpricedModels: ["fixture-unknown"]), "unpriced"),
            (.zero, "$0.00"),
            (.unpriced, "unpriced"),
        ] {
            input.todayCostInputs = [.init(name: "Grok", value: value)]
            #expect(try self.model(.grok, input: input).today == expected)
        }
    }

    private func model(
        _ provider: UsageProvider,
        input: PacePanelInput,
        context: PaceProviderTabContext? = nil) throws -> PaceProviderTabModel
    {
        let block = try #require(PacePanelModel.make(input).providers.first { $0.provider == provider })
        return PaceProviderTabModel.make(block: block, input: input, context: context)
    }

    static func fixture() -> PacePanelInput {
        let now = Date(timeIntervalSince1970: 1_793_620_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func window(_ used: Double, _ minutes: Int?, _ left: Double) -> RateWindow {
            .init(
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: now.addingTimeInterval(left * 60),
                resetDescription: nil)
        }
        let session = window(6, 300, 228)
        let weekly = window(42, 10080, 2640)
        let fable = window(4, 10080, 2640)
        var input = PacePanelInput(
            providers: [.codex, .claude, .grok],
            snapshots: [
                .codex: .init(primary: nil, secondary: window(54, 10080, 2888), updatedAt: now),
                .claude: .init(
                    primary: session,
                    secondary: weekly,
                    extraRateWindows: [.init(id: "claude-weekly-scoped-fable", title: "Fable", window: fable)],
                    updatedAt: now),
                .grok: .init(primary: window(5, nil, 7020), secondary: nil, updatedAt: now),
            ],
            todayCostInputs: [
                .init(name: "Codex", value: .exact(37.54)), .init(name: "Claude", value: .exact(25.11)),
                .init(name: "Grok", value: .exact(7.96)),
            ],
            now: now,
            calendar: calendar)
        for provider in input.providers {
            let block = PacePanelModel.make(input).providers.first { $0.provider == provider }
            input.histories[provider] = block?.windows.compactMap { row in
                guard let pace = row.pace, let name = row.series else { return nil }
                let reset = now.addingTimeInterval(Double(pace.durationMinutes) * 60 * (1 - pace.fractionElapsed))
                return .init(name: name, windowMinutes: pace.durationMinutes, entries: [
                    .init(
                        capturedAt: now.addingTimeInterval(-1800),
                        usedPercent: max(0, 100 - row.fillPercent - 3),
                        resetsAt: reset),
                    .init(
                        capturedAt: now.addingTimeInterval(-900),
                        usedPercent: max(0, 100 - row.fillPercent - 1),
                        resetsAt: reset),
                ])
            }
            let amount = input.todayCostInputs.first { $0.name == block?.name }?.value.usd ?? 0
            let name = provider == .grok ? "grok-4-0709" : (provider == .claude ? "claude-opus-4-1" : "gpt-5")
            input.tokenSnapshots[provider] = self.costSnapshot(now: now, daily: [
                self.entry(date: "2026-10-29", cost: 30, models: [.init(modelName: name, costUSD: 30)]),
                self.entry(date: "2026-10-30", cost: 18, models: [.init(modelName: name, costUSD: 18)]),
                self.entry(date: "2026-11-01", cost: 12, models: [.init(modelName: name, costUSD: 12)]),
                self.entry(date: "2026-11-02", cost: amount, models: [.init(modelName: name, costUSD: amount)]),
            ])
        }
        return input
    }

    static func context(
        provider: UsageProvider,
        input: PacePanelInput,
        error: String? = nil) -> PaceProviderTabContext
    {
        let plan = provider == .grok ? "SuperGrok" : (provider == .claude ? "Max 5x" : "Pro")
        var card = UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: ProviderDescriptorRegistry.descriptor(for: provider).metadata,
            snapshot: input.snapshots[provider],
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: input.tokenSnapshots[provider],
            tokenError: nil,
            account: .init(email: "pace@example.test", plan: plan),
            accountIsAuthoritative: true,
            planOverride: .label(plan),
            isRefreshing: false,
            lastError: error,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            preferredCurrencyCode: "USD",
            now: input.now))
        if provider == .claude {
            card.cloudCredits = .init(
                title: "Cloud credits", percentUsed: nil, spendLine: "$185.84", percentLine: nil)
            card.providerCost = .init(
                title: "Extra usage", percentUsed: 0, spendLine: "$0.00 of $50.00", percentLine: nil)
        }
        return PaceProviderTabContext(
            card: card,
            menu: .init(sections: [.init(entries: [
                .action("Usage Dashboard", .dashboard), .action("Status Page", .statusPage),
                .action("Changelog", .changelog), .action("Add Account", .addProviderAccount(provider)),
                .action("Switch Account", .switchAccount(provider)), .action("Add Codex Account", .addCodexAccount),
                .action("Refresh", .refresh), .action("Settings", .settings),
                .action("About", .about), .action("Quit", .quit),
                .text("Agent Sessions", .headline),
                .action("Fixture agent", .focusAgentSession(AgentSession(
                    id: "pace-fixture",
                    provider: .codex,
                    source: .cli,
                    state: .active,
                    pid: 42,
                    cwd: "/fixture",
                    projectName: "fixture",
                    sessionName: nil,
                    startedAt: nil,
                    lastActivityAt: input.now,
                    transcriptPath: nil,
                    host: "fixture"), remoteHost: nil)),
            ])]),
            accountCount: 1,
            error: error)
    }

    static func entry(date: String, cost: Double?, models: [CostUsageDailyReport.ModelBreakdown] = [])
    -> CostUsageDailyReport.Entry {
        .init(
            date: date,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 1000,
            costUSD: cost,
            modelsUsed: models.map(\.modelName),
            modelBreakdowns: models)
    }

    static func costSnapshot(now: Date, daily: [CostUsageDailyReport.Entry]) -> CostUsageTokenSnapshot {
        .init(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: daily,
            updatedAt: now)
    }
}
