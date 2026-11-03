import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PaceSamplerTests {
    private let now = Date(timeIntervalSince1970: 1_793_577_600)

    @Test(arguments: [
        (nil as Int?, "weekly", 10080), (10500, "weekly", 10500),
        (10079, "weekly", 10080), (43200, "monthly", 43200), (60, "credits", 60),
    ])
    func `T10 Grok records without opt in and keeps raw nonstandard durations`(
        minutes: Int?, name: String, storedMinutes: Int) async throws
    {
        let store = self.makeStore()
        let snapshot = UsageSnapshot(
            primary: self.window(used: 5, minutes: minutes), secondary: nil, updatedAt: self.now)
        #expect(!store.settings.historicalTrackingEnabled)
        await store.recordPlanUtilizationHistorySample(provider: .grok, snapshot: snapshot, now: self.now)
        let history = try #require(store.planUtilizationHistory(for: .grok).first)
        #expect(history.name.rawValue == name)
        #expect(history.windowMinutes == storedMinutes)
        #expect(history.entries == [PlanUtilizationHistoryEntry(
            capturedAt: self.now, usedPercent: 5, resetsAt: snapshot.primary?.resetsAt)])
    }

    @Test func `T10c Pace off preserves the historical opt in gate`() async {
        let store = self.makeStore()
        store.settings.menuBarGroupsProviderIcons = false
        let snapshot = UsageSnapshot(
            primary: self.window(used: 5, minutes: nil), secondary: nil, updatedAt: self.now)
        await store.recordPlanUtilizationHistorySample(provider: .grok, snapshot: snapshot, now: self.now)
        #expect(store.planUtilizationHistory(for: .grok).isEmpty)
        #expect(store.paceSamplerSamples(provider: .grok, snapshot: snapshot, capturedAt: self.now, excluding: [])
            .isEmpty)
    }

    @Test(arguments: [nil as Int?, 10080, 10500])
    func `T11 generic reconciliation keeps two Grok captures an hour apart`(minutes: Int?) async throws {
        let store = self.makeStore()
        let snapshot = UsageSnapshot(
            primary: self.window(used: 5, minutes: minutes), secondary: nil, updatedAt: self.now)
        for date in [self.now, self.now.addingTimeInterval(3600)] {
            await store.recordPlanUtilizationHistorySample(provider: .grok, snapshot: snapshot, now: date)
        }
        let history = try #require(store.planUtilizationHistory(for: .grok).first)
        #expect(history.name == .weekly)
        #expect(history.entries.map(\.usedPercent) == [5, 5])
        #expect(history.entries.map(\.capturedAt) == [self.now, self.now.addingTimeInterval(3600)])
    }

    @Test func `T12 Claude extra windows leave detector samples and reset events unchanged`() async throws {
        let store = self.makeStore()
        let email = "pace-sampler-extra@example.com"
        let weeklyEvents = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: email)
        let sessionEvents = SessionLimitResetEventRecorder(provider: .claude, accountLabel: email)
        defer {
            weeklyEvents.invalidate()
            sessionEvents.invalidate()
        }
        let primary = self.window(used: 6, minutes: 300, remainingMinutes: 228)
        let secondary = self.window(used: 42, minutes: 10080, remainingMinutes: 2640)
        let baseline = UsageSnapshot(primary: primary, secondary: secondary, updatedAt: self.now)
        let detectorSamples = store.planUtilizationSeriesSamples(
            provider: .claude, snapshot: baseline, capturedAt: self.now)
        #expect(detectorSamples.map(\.name) == [.session, .weekly])
        for (offset, used) in [99.0, 4.0, 4.0].enumerated() {
            let snapshot = UsageSnapshot(
                primary: primary,
                secondary: secondary,
                extraRateWindows: [NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable",
                    window: self.window(used: used, minutes: 10080, remainingMinutes: offset == 0 ? 60 : 2640))],
                updatedAt: self.now,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude, accountEmail: email, accountOrganization: nil, loginMethod: "max"))
            let samples = store.planUtilizationSeriesSamples(
                provider: .claude, snapshot: snapshot, capturedAt: self.now)
            #expect(samples.map(\.name) == detectorSamples.map(\.name))
            #expect(samples.map(\.entry) == detectorSamples.map(\.entry))
            await store.recordPlanUtilizationHistorySample(
                provider: .claude, snapshot: snapshot, now: self.now.addingTimeInterval(Double(offset) * 3600))
        }
        let history = try #require(store.planUtilizationHistory(for: .claude).first {
            $0.name.rawValue == "extra:claude-weekly-scoped-fable"
        })
        #expect(history.windowMinutes == 10080)
        #expect(history.entries.map(\.usedPercent) == [99, 4, 4])
        #expect(weeklyEvents.events.isEmpty)
        #expect(sessionEvents.events.isEmpty)
    }

    @Test func `new Grok weekly samples never enter the weekly reset detector`() async {
        let store = self.makeStore()
        for (offset, used) in [99.0, 0.0, 0.0].enumerated() {
            let snapshot = UsageSnapshot(
                primary: self.window(used: used, minutes: nil), secondary: nil, updatedAt: self.now)
            await store.recordPlanUtilizationHistorySample(
                provider: .grok, snapshot: snapshot, now: self.now.addingTimeInterval(Double(offset) * 3600))
        }
        #expect(store.weeklyLimitResetDetectorStates.isEmpty)
        #expect(store.planUtilizationHistory(for: .grok).first?.entries.count == 3)
    }

    @Test func `sampler records every enabled provider without a history capability allowlist`() async {
        let store = self.makeStore()
        enableTestProviders(Set(UsageProvider.allCases), settings: store.settings)
        for provider in UsageProvider.allCases {
            let snapshot = UsageSnapshot(
                primary: self.window(used: 17, minutes: 60), secondary: nil, updatedAt: self.now)
            await store.recordPlanUtilizationHistorySample(provider: provider, snapshot: snapshot, now: self.now)
            #expect(store.planUtilizationHistory(for: provider).contains {
                $0.windowMinutes == 60 && $0.entries.first?.usedPercent == 17
            }, "Missing provider: \(provider.rawValue)")
        }
    }

    private func makeStore(
        historyStore: PlanUtilizationHistoryStore? = nil,
        defaults: UserDefaults = InMemoryUserDefaults()) -> UsageStore
    {
        let settings = testSettingsStore(suiteName: "PaceSamplerTests", userDefaults: defaults)
        enableTestProviders([.codex, .claude, .grok, .chatbox], settings: settings)
        settings.mergeIcons = true
        settings.menuBarGroupsProviderIcons = true
        settings.historicalTrackingEnabled = false
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: historyStore ?? PlanUtilizationHistoryStore(directoryURL: nil),
            startupBehavior: .testing)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        store.planUtilizationHistory = [:]
        return store
    }

    private func window(
        used: Double = 5,
        minutes: Int? = 10080,
        remainingMinutes: Double = 7020,
        synthetic: Bool = false) -> RateWindow
    {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: self.now.addingTimeInterval(remainingMinutes * 60),
            resetDescription: nil,
            isSyntheticPlaceholder: synthetic)
    }
}

extension PaceSamplerTests {
    @Test func `Grok cadence transitions keep new samples outside generic reconciliation`() async throws {
        let store = self.makeStore()
        for (offset, minutes) in [10080 as Int?, nil, 10500, 10080].enumerated() {
            let snapshot = UsageSnapshot(
                primary: self.window(used: 5, minutes: minutes), secondary: nil, updatedAt: self.now)
            await store.recordPlanUtilizationHistorySample(
                provider: .grok, snapshot: snapshot, now: self.now.addingTimeInterval(Double(offset) * 3600))
        }
        let histories = store.planUtilizationHistory(for: .grok)
        let canonical = try #require(histories.first { $0.name == .weekly && $0.windowMinutes == 10080 })
        let raw = try #require(histories.first { $0.name == .weekly && $0.windowMinutes == 10500 })
        #expect(canonical.entries.map(\.capturedAt) == [
            self.now, self.now.addingTimeInterval(3600), self.now.addingTimeInterval(10800),
        ])
        #expect(raw.entries.map(\.capturedAt) == [self.now.addingTimeInterval(7200)])
    }

    @Test func `Pace history reads bypass unavailable capability only while active`() async {
        let store = self.makeStore()
        let provider = UsageProvider.chatbox
        #expect(!ProviderDescriptorRegistry.descriptor(for: provider).history.supportsPlanUtilization)
        let snapshot = UsageSnapshot(
            primary: self.window(used: 17, minutes: 60),
            secondary: nil,
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: "pace-chatbox@example.com",
                accountOrganization: nil,
                loginMethod: "test"))
        await store.recordPlanUtilizationHistorySample(provider: provider, snapshot: snapshot, now: self.now)
        #expect(store.supportsPlanUtilizationHistory(for: provider))
        #expect(store.planUtilizationHistorySelection(for: provider, snapshotOverride: snapshot).histories.count == 1)
        let account = ProviderTokenAccount(id: UUID(), label: "Fixture", token: "fixture", addedAt: 0, lastUsed: nil)
        await store.recordPlanUtilizationHistorySample(
            provider: provider, snapshot: snapshot, account: account, now: self.now.addingTimeInterval(3600))
        #expect(store.planUtilizationHistorySelection(for: provider, account: account).histories.count == 1)
        store.settings.mergeIcons = false
        #expect(!store.supportsPlanUtilizationHistory(for: provider))
        #expect(!store.shouldRecordPlanUtilizationHistory(for: provider))
        #expect(store.planUtilizationHistory(for: provider).isEmpty)
        #expect(store.planUtilizationHistorySelection(for: provider, snapshotOverride: snapshot).histories.isEmpty)
        #expect(store.planUtilizationHistorySelection(for: provider, account: account).histories.isEmpty)
        let revision = store.planUtilizationHistoryRevision
        await store.recordPlanUtilizationHistorySample(
            provider: provider, snapshot: snapshot, account: account, now: self.now.addingTimeInterval(7200))
        #expect(store.planUtilizationHistoryRevision == revision)
    }

    @Test func `sampler excludes existing canonical series and keeps raw extra durations`() {
        let store = self.makeStore()
        let snapshot = UsageSnapshot(
            primary: self.window(minutes: 299),
            secondary: self.window(minutes: 10079),
            tertiary: self.window(minutes: 10080),
            extraRateWindows: [NamedRateWindow(
                id: "fable", title: "Fable", window: self.window(minutes: 10079))],
            updatedAt: self.now)
        let existing = store.planUtilizationSeriesSamples(provider: .claude, snapshot: snapshot, capturedAt: self.now)
        #expect(existing.map(\.name) == [.session, .opus, .weekly])
        let added = store.paceSamplerSamples(
            provider: .claude, snapshot: snapshot, capturedAt: self.now, excluding: existing)
        #expect(added.map(\.name.rawValue) == ["extra:fable"])
        #expect(added.map(\.windowMinutes) == [10079])
    }

    @Test func `invalid and unknown extra observations do not become samples`() {
        let store = self.makeStore()
        let invalid = [
            self.window(synthetic: true), self.window(used: .nan), self.window(used: .infinity),
            self.window(minutes: nil), self.window(minutes: 0), self.window(minutes: -1),
        ]
        let snapshot = UsageSnapshot(
            primary: invalid[0],
            secondary: invalid[1],
            tertiary: invalid[2],
            extraRateWindows: invalid.enumerated().map { offset, window in
                NamedRateWindow(id: "invalid-\(offset)", title: "Invalid", window: window)
            } + [NamedRateWindow(id: "unknown", title: "Unknown", window: self.window(), usageKnown: false)],
            updatedAt: self.now)
        #expect(store.paceSamplerSamples(
            provider: .claude, snapshot: snapshot, capturedAt: self.now, excluding: []).isEmpty)
    }

    @Test func `Pace compacts reset split hours to the latest segment peak`() async throws {
        let store = self.makeStore()
        for (offset, used) in [99.0, 4.0, 9.0, 6.0].enumerated() {
            let snapshot = UsageSnapshot(
                primary: self.window(used: used, minutes: nil, remainingMinutes: offset == 0 ? 60 : 7020),
                secondary: nil,
                updatedAt: self.now)
            await store.recordPlanUtilizationHistorySample(
                provider: .grok, snapshot: snapshot, now: self.now.addingTimeInterval(Double(offset) * 600))
        }
        let history = try #require(store.planUtilizationHistory(for: .grok).first)
        #expect(history.entries.count == 1)
        #expect(history.entries.first?.usedPercent == 9)
        #expect(history.entries.first?.capturedAt == self.now.addingTimeInterval(1200))
    }

    @Test func `Pace compacts old split hours and retains the existing entry bound`() throws {
        let first = PlanUtilizationHistoryEntry(capturedAt: self.now, usedPercent: 99, resetsAt: self.now)
        let reset = PlanUtilizationHistoryEntry(
            capturedAt: self.now.addingTimeInterval(600),
            usedPercent: 4,
            resetsAt: self.now.addingTimeInterval(604_800))
        let legacy = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [first, reset])
        let compacted = try #require(UsageStore.updatedPaceSamplerHistories(existingHistories: [legacy], samples: []))
        #expect(compacted.first?.entries == [reset])
        let entries = (0..<17520).map {
            PlanUtilizationHistoryEntry(
                capturedAt: self.now.addingTimeInterval(Double($0) * 3600), usedPercent: 5, resetsAt: nil)
        }
        let history = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: entries)
        let last = PlanUtilizationHistoryEntry(
            capturedAt: self.now.addingTimeInterval(17520 * 3600), usedPercent: 6, resetsAt: nil)
        let retained = try #require(UsageStore.updatedPaceSamplerHistories(
            existingHistories: [history], samples: [.init(name: .weekly, windowMinutes: 10080, entry: last)]))
        #expect(retained.first?.entries.count == 17520)
        #expect(retained.first?.entries.first == entries[1])
        #expect(retained.first?.entries.last == last)
    }
}

extension PaceSamplerTests {
    @Test(arguments: [UsageProvider.grok, .chatbox, .claude], [0, 1, 2])
    func `24 hours persist only completed canonical samples and resets`(
        provider: UsageProvider, scenario: Int) async throws
    {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let writes = PaceHistoryWriteRecorder()
        let historyStore = PlanUtilizationHistoryStore(directoryURL: environment.root) { _, bytes in
            writes.record(bytes)
        }
        let store = self.makeStore(historyStore: historyStore)
        for cycle in 0..<288 {
            let date = self.now.addingTimeInterval(Double(cycle) * 300)
            let reset = scenario == 2 && cycle >= 150
            let used = scenario == 0 ? 5.0 : Double((cycle % 12) + (reset ? 1 : 20))
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: used,
                    windowMinutes: 10080,
                    resetsAt: self.now.addingTimeInterval(reset ? 1_209_600 : 604_800),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: date)
            await store.recordPlanUtilizationHistorySample(provider: provider, snapshot: snapshot, now: date)
            await store.planUtilizationPersistenceCoordinator.waitForPendingWrites()
            if cycle < 12 { #expect(writes.bytes.isEmpty) }
            let diskCount = historyStore.load()[provider.instanceID]?.unscoped.first?.entries.count ?? 0
            let memoryCount = store.planUtilizationHistory(for: provider).first?.entries.count ?? 0
            #expect(memoryCount - diskCount <= 1)
        }
        await store.persistPlanUtilizationHistoryForTermination()?.value
        let bytes = writes.bytes
        #expect(bytes.count == (scenario == 2 ? 25 : 24))
        #expect(bytes.allSatisfy { $0 > 0 })
        let expectedBytes = provider == .claude ? [29664, 29964, 31256] : [31128, 31428, 32781]
        #expect(bytes.reduce(0, +) == expectedBytes[scenario])
        #expect(!writes.wroteOnMainThread)
        #expect(historyStore.load() == store.planUtilizationHistory)
        #expect(store.planUtilizationHistory(for: provider).first?.entries.count == 24)
        let before = bytes.count
        await store.planUtilizationPersistenceCoordinator.flush(store.planUtilizationHistory)
        #expect(writes.bytes.count == before)
        print("PaceIO provider=\(provider.rawValue) scenario=\(scenario) writes=\(bytes.count) "
            + "bytes=\(bytes.reduce(0, +)) per_write=\(bytes)")
    }

    @Test(arguments: [UsageProvider.grok, .chatbox, .claude])
    func `Pace off retains fork next persistence behavior`(provider: UsageProvider) async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let writes = PaceHistoryWriteRecorder()
        let historyStore = PlanUtilizationHistoryStore(directoryURL: environment.root) { _, bytes in
            writes.record(bytes)
        }
        let store = self.makeStore(historyStore: historyStore)
        store.settings.menuBarGroupsProviderIcons = false
        for cycle in 0..<288 {
            let date = self.now.addingTimeInterval(Double(cycle) * 300)
            let snapshot = UsageSnapshot(
                primary: self.window(used: 5), secondary: nil, updatedAt: date)
            await store.recordPlanUtilizationHistorySample(provider: provider, snapshot: snapshot, now: date)
            await store.planUtilizationPersistenceCoordinator.waitForPendingWrites()
        }
        #expect(writes.bytes.count == (provider == .claude ? 288 : 0))
        print("NextIO provider=\(provider.rawValue) writes=\(writes.bytes.count) "
            + "bytes=\(writes.bytes.reduce(0, +))")
    }

    @Test func `restart in the same hour does not rewrite a timestamp only refresh`() async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let writes = PaceHistoryWriteRecorder()
        let historyStore = PlanUtilizationHistoryStore(directoryURL: environment.root) { _, bytes in
            writes.record(bytes)
        }
        let first = self.makeStore(historyStore: historyStore)
        let snapshot = UsageSnapshot(primary: self.window(), secondary: nil, updatedAt: self.now)
        await first.recordPlanUtilizationHistorySample(provider: .grok, snapshot: snapshot, now: self.now)
        await first.persistPlanUtilizationHistoryForTermination()?.value
        let store = self.makeStore(historyStore: historyStore)
        store.planUtilizationHistory = historyStore.load()
        await store.recordPlanUtilizationHistorySample(
            provider: .grok, snapshot: snapshot, now: self.now.addingTimeInterval(300))
        await store.planUtilizationPersistenceCoordinator.waitForPendingWrites()
        #expect(writes.bytes.count == 1)
        #expect(store.planUtilizationHistory(for: .grok).first?.entries.last?.capturedAt
            == self.now.addingTimeInterval(300))
    }

    @Test func `cadence changes flush the previous pending window before starting another`() async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let historyStore = PlanUtilizationHistoryStore(directoryURL: environment.root)
        let store = self.makeStore(historyStore: historyStore)
        for (offset, minutes) in [10080, 10500].enumerated() {
            let snapshot = UsageSnapshot(
                primary: self.window(minutes: minutes), secondary: nil, updatedAt: self.now)
            await store.recordPlanUtilizationHistorySample(
                provider: .grok, snapshot: snapshot, now: self.now.addingTimeInterval(Double(offset) * 300))
        }
        await store.planUtilizationPersistenceCoordinator.waitForPendingWrites()
        #expect(historyStore.load() == store.planUtilizationHistory)
        #expect(historyStore.load()[.grok]?.unscoped.map(\.windowMinutes) == [10080, 10500])
    }

    @Test(arguments: [0, 1, 2])
    func `Pace only providers do not add reset detector persistence`(scenario: Int) async {
        let writes = PaceHistoryWriteRecorder()
        let defaults = InMemoryUserDefaults { key, bytes in
            if key == UsageStore.sessionLimitResetDetectorDefaultsKey
                || key == UsageStore.weeklyLimitResetDetectorDefaultsKey
            {
                writes.record(bytes)
            }
        }
        let store = self.makeStore(defaults: defaults)
        for cycle in 0..<288 {
            let reset = scenario == 2 && cycle >= 150
            let date = self.now.addingTimeInterval(Double(cycle) * 300)
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: scenario == 0 ? 5 : Double(reset ? 2 : 20 + cycle % 12),
                    windowMinutes: 60,
                    resetsAt: self.now.addingTimeInterval(reset ? 7200 : 3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: date)
            await store.recordPlanUtilizationHistorySample(provider: .chatbox, snapshot: snapshot, now: date)
        }
        print("PaceDetectorIO scenario=\(scenario) writes=\(writes.bytes.count) "
            + "bytes=\(writes.bytes.reduce(0, +)) per_write=\(Set(writes.bytes).sorted())")
        #expect(writes.bytes.isEmpty)
        #expect(store.sessionLimitResetDetectorStates.isEmpty)
        #expect(store.planUtilizationHistory(for: .chatbox).first?.entries.count == 24)
        if scenario == 2 {
            let entry = store.planUtilizationHistory(for: .chatbox).first?.entries[12]
            #expect(entry?.usedPercent == 2)
            #expect(entry?.resetsAt == self.now.addingTimeInterval(7200))
        }
    }
}

private final class PaceHistoryWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedBytes: [Int] = []
    private var recordedMainThread = false

    var bytes: [Int] {
        self.lock.withLock { self.recordedBytes }
    }

    var wroteOnMainThread: Bool {
        self.lock.withLock { self.recordedMainThread }
    }

    func record(_ bytes: Int) {
        self.lock.withLock {
            self.recordedBytes.append(bytes)
            self.recordedMainThread = self.recordedMainThread || Thread.isMainThread
        }
    }
}
