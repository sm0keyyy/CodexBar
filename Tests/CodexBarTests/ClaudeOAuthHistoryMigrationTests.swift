import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeOAuthHistoryMigrationTests {
    @Test
    func `copied live shape merges the renewal tail once without touching other providers`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-oauth-renewal-fragments.json")
        let file = directory.appendingPathComponent("claude.json")
        try FileManager.default.copyItem(at: fixture, to: file)
        let codexFile = directory.appendingPathComponent("codex.json")
        let untouched = Data("unreadable provider history must remain untouched".utf8)
        try untouched.write(to: codexFile)
        let writes = MigrationWrites()
        let store = PlanUtilizationHistoryStore(directoryURL: directory, didWrite: { _, _ in writes.record() })

        let buckets = try #require(store.load()[.claude])
        let preferred = try #require(buckets.preferredAccountKey)
        let histories = try #require(buckets.accounts[preferred])
        #expect(buckets.accounts.count == 4)
        #expect(histories.first { $0.name == .session }?.entries.count == 37)
        #expect(histories.first { $0.name == .weekly }?.entries.count == 37)
        #expect(histories.first { $0.name.rawValue == "extra:claude-weekly-scoped-fixture" }?.entries.count == 10)
        #expect(buckets.accounts["legacy-8"]?.first?.entries.count == 2)
        #expect(buckets.accounts["legacy-9"]?.first?.entries.count == 2)
        for history in histories {
            let hours = history.entries.map { UsageStore.planUtilizationHourBucket(for: $0.capturedAt) }
            #expect(Set(hours).count == hours.count)
        }
        #expect(writes.count == 1)
        let migrated = try Data(contentsOf: file)
        #expect(store.load()[.claude] == buckets)
        #expect(try Data(contentsOf: file) == migrated)
        #expect(try Data(contentsOf: codexFile) == untouched)
        #expect(writes.count == 1)
    }

    @MainActor
    @Test
    func `first profile after another renewal adopts the compatible loaded tail`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-oauth-renewal-fragments.json")
        try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("claude.json"))
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.planUtilizationHistory = PlanUtilizationHistoryStore(directoryURL: directory).load()
        let previousKey = try #require(store.planUtilizationHistory[.claude]?.preferredAccountKey)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-03T22:00:00Z"))
        let weeklyReset = try #require(ISO8601DateFormatter().date(from: "2026-11-04T21:00:00Z"))
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(10800), resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: 10080, resetsAt: weeklyReset, resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude, accountEmail: "fixture@example.com", accountOrganization: nil, loginMethod: nil))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            claudeOAuthHistoryOwnerIdentifier: String(repeating: "f", count: 64),
            claudeOAuthProfileIdentity: UsageStore.legacyClaudePlanUtilizationEmailAccountKey(snapshot: snapshot),
            claudeOAuthKeychainCredentialUnavailable: true,
            isClaudeOAuthSample: true,
            now: now)
        let buckets = try #require(store.planUtilizationHistory[.claude])
        let preferred = try #require(buckets.preferredAccountKey)
        #expect(preferred != previousKey)
        #expect(buckets.accounts[previousKey] == nil)
        #expect(buckets.accounts.count == 4)
        #expect(buckets.accounts[preferred]?.first { $0.name == .session }?.entries.count == 38)
        #expect(buckets.accounts[preferred]?.first { $0.name == .weekly }?.entries.count == 38)
    }

    @Test(arguments: [false, true])
    func `profile adoption preserves known and quarantined accounts`(quarantined: Bool) throws {
        let oldOwner = String(repeating: "a", count: 64)
        let newIdentity = String(repeating: "b", count: 64)
        let preferred = try #require(UsageStore.claudeOAuthPlanUtilizationAccountKey(historyOwnerIdentifier: oldOwner))
        let target = try #require(UsageStore.claudeOAuthPlanUtilizationAccountKey(historyOwnerIdentifier: newIdentity))
        var buckets = PlanUtilizationHistoryBuckets(
            preferredAccountKey: preferred, accounts: [preferred: self.histories(first: 1, last: 2)])
        let original = buckets
        let following = self.histories(first: 3, last: 4).map {
            UsageStore.PlanUtilizationSeriesSample(name: $0.name, windowMinutes: $0.windowMinutes, entry: $0.entries[0])
        }
        var bindings = ["profile:new-owner": newIdentity]
        if quarantined {
            bindings["unverified:\(preferred)"] = String(repeating: "c", count: 64)
        } else {
            bindings[oldOwner] = String(repeating: "c", count: 64)
        }
        buckets.adoptClaudeOAuthLegacyTail(into: target, following: following, bindings: bindings)
        #expect(buckets == original)
    }

    @Test(arguments: [false, true], [false, true])
    func `async load does not merge known or quarantined scopes`(
        quarantined: Bool, preferredIsKnown: Bool) async throws
    {
        let owner = String(repeating: "a", count: 64)
        let known = try #require(UsageStore.claudeOAuthPlanUtilizationAccountKey(historyOwnerIdentifier: owner))
        var keys = [self.key(1), self.key(2), self.key(3)]
        keys[preferredIsKnown ? 2 : 1] = known
        let original = PlanUtilizationHistoryBuckets(
            preferredAccountKey: keys[2],
            accounts: Dictionary(uniqueKeysWithValues: keys.enumerated().map { index, key in
                (key, self.histories(first: Double(index * 2 + 1), last: Double(index * 2 + 2)))
            }))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlanUtilizationHistoryStore(directoryURL: directory)
        store.save([.claude: original])
        let file = directory.appendingPathComponent("claude.json")
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        payload.removeValue(forKey: "claudeOAuthFragmentMigrationVersion")
        try JSONSerialization.data(withJSONObject: payload).write(to: file, options: .atomic)
        let bindingKey = quarantined ? "unverified:\(known)" : owner
        let loaded = await store.loadAsync(claudeOAuthBindings: [bindingKey: String(repeating: "b", count: 64)])
        #expect(loaded[.claude] == original)
    }

    @Test(arguments: [
        "overlap", "weekly reset", "gap", "cutover", "missing weekly", "session reset", "missing reset", "cadence",
    ])
    func `ambiguous fragments remain separate`(conflict: String) {
        var earlier = self.histories(first: 1, last: conflict == "overlap" ? 3.5 : 2)
        var later = self.histories(first: conflict == "gap" ? 16 : 3, last: 17)
        if conflict == "weekly reset" { later = self.histories(first: 3, last: 4, weeklyReset: 201) }
        if conflict == "session reset" { later = self.histories(first: 3, last: 4, sessionReset: 13) }
        if conflict == "missing weekly" { earlier.removeAll { $0.name == .weekly } }
        if conflict == "missing reset" {
            earlier = earlier.map {
                PlanUtilizationSeriesHistory(name: $0.name, windowMinutes: $0.windowMinutes, entries: $0.entries.map {
                    PlanUtilizationHistoryEntry(capturedAt: $0.capturedAt, usedPercent: $0.usedPercent, resetsAt: nil)
                })
            }
        }
        if conflict == "cadence", let weekly = later.first(where: { $0.name == .weekly }) {
            later.removeAll { $0.name == .weekly }
            later.append(PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 9000, entries: weekly.entries))
        }
        let legacy = self.histories(first: 0, last: conflict == "cutover" ? 2.5 : 0)
        var buckets = PlanUtilizationHistoryBuckets(preferredAccountKey: self.key(2), accounts: [
            self.key(1): earlier, self.key(2): later, "legacy": legacy,
        ])
        let original = buckets
        buckets.migrateClaudeOAuthFragments()
        #expect(buckets == original)
    }

    @Test
    func `migration keeps latest canonical hourly samples under the two year cap`() throws {
        let reset = self.date(30000)
        let entries = (0...17520).map {
            PlanUtilizationHistoryEntry(capturedAt: self.date(Double($0)), usedPercent: 10, resetsAt: reset)
        }
        let earlier = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: entries)
        let later = PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: 10080, entries: [
            PlanUtilizationHistoryEntry(capturedAt: self.date(17520.5), usedPercent: 20, resetsAt: reset),
            PlanUtilizationHistoryEntry(capturedAt: self.date(17521), usedPercent: 30, resetsAt: reset),
        ])
        var buckets = PlanUtilizationHistoryBuckets(preferredAccountKey: self.key(2), accounts: [
            self.key(1): [earlier], self.key(2): [later],
        ])
        buckets.migrateClaudeOAuthFragments()
        let result = try #require(buckets.accounts[self.key(2)]?.first?.entries)
        #expect(result.count == 17520)
        #expect(result.first?.capturedAt == self.date(2))
        #expect(result.suffix(2).map(\.usedPercent) == [20, 30])
    }

    private func key(_ value: Int) -> String { "__claude_oauth__:\(value)" }

    private func date(_ hour: Double) -> Date { Date(timeIntervalSince1970: hour * 3600) }

    private func histories(
        first: Double,
        last: Double,
        weeklyReset: Double = 200,
        sessionReset: Double = 12) -> [PlanUtilizationSeriesHistory]
    {
        [(PlanUtilizationSeriesName.session, 300, sessionReset), (.weekly, 10080, weeklyReset)]
            .map { name, minutes, reset in
                PlanUtilizationSeriesHistory(name: name, windowMinutes: minutes, entries: [first, last].map {
                    PlanUtilizationHistoryEntry(capturedAt: self.date($0), usedPercent: 10, resetsAt: self.date(reset))
                })
            }
    }
}

private final class MigrationWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        self.lock.withLock { self.value }
    }

    func record() { self.lock.withLock { self.value += 1 } }
}
