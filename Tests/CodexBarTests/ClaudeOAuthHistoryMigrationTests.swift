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

    @Test(arguments: ["overlap", "weekly reset", "gap", "cutover", "missing weekly", "session reset"])
    func `ambiguous fragments remain separate`(conflict: String) {
        var earlier = self.histories(first: 1, last: conflict == "overlap" ? 3.5 : 2)
        var later = self.histories(first: conflict == "gap" ? 16 : 3, last: 17)
        if conflict == "weekly reset" { later = self.histories(first: 3, last: 4, weeklyReset: 201) }
        if conflict == "session reset" { later = self.histories(first: 3, last: 4, sessionReset: 13) }
        if conflict == "missing weekly" { earlier.removeAll { $0.name == .weekly } }
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
