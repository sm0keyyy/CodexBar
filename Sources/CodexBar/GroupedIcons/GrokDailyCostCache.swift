import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class GrokDailyCostCache {
    static let shared = GrokDailyCostCache()
    var today: GrokDayCost?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var day: Date?
    @ObservationIgnored private var inputSignature: String?
    @ObservationIgnored private var mirrorSignature: PiSessionCostScanner.GrokSourceSignature?
    @ObservationIgnored private var mirrorReport: CostUsageDailyReport?
    @ObservationIgnored private var didLogReadError = false

    func refreshIfNeeded(now: Date) {
        guard !TestProcessSafety.isRunning else { return }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        if self.day != day {
            self.today = nil
            self.inputSignature = nil
            self.day = day
        }
        guard self.task == nil else { return }
        guard self.lastAttempt.map({ now.timeIntervalSince($0) >= 60 }) ?? true
            || self.lastAttempt.map({ !calendar.isDate($0, inSameDayAs: now) }) == true else { return }
        self.lastAttempt = now
        let signature = self.inputSignature
        let previousMirrorSignature = self.mirrorSignature
        let previousMirrorReport = self.mirrorReport
        let home = GrokCredentialsStore.grokHomeURL()
        self.task = Task { [weak self] in
            let result: Result<Scan, Error>
            do {
                await CostUsagePricing.refreshGrokPricingIfNeeded(
                    now: now, unpricedModels: self?.today?.unpricedModels ?? [])
                // Provider-specific by design: Grok mirror work must not queue ahead of native provider results.
                let scan = try await CostUsageScanExecutor.run(provider: .grok) { _ in
                    defer { MemoryPressureRelief.releaseFreeMallocPages() }
                    return try autoreleasepool {
                        let since = calendar.date(byAdding: .day, value: -30, to: now) ?? now
                        let mirrorSignature = try PiSessionCostScanner.grokSourceSignature(now: now, calendar: calendar)
                        let mirrors: CostUsageDailyReport = if mirrorSignature == previousMirrorSignature,
                                                               let previousMirrorReport
                        {
                            previousMirrorReport
                        } else {
                            try PiSessionCostScanner.grokDailyReport(
                                since: since, until: now, now: now, calendar: calendar)
                        }
                        var scan = try Self.scan(
                            home: home,
                            now: now,
                            calendar: calendar,
                            previousSignature: signature,
                            mirrors: mirrors)
                        scan.mirrorSignature = mirrorSignature
                        scan.mirrorReport = mirrors
                        return scan
                    }
                }
                result = .success(scan)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            defer { self.task = nil }
            guard calendar.isDate(Date(), inSameDayAs: now) else { return }
            switch result {
            case let .success(scan):
                self.inputSignature = scan.signature
                self.mirrorSignature = scan.mirrorSignature
                self.mirrorReport = scan.mirrorReport
                if let cost = scan.cost { self.today = cost }
            case .failure:
                if !self.didLogReadError {
                    CodexBarLog.logger(LogCategories.app)
                        .warning("Grouped Grok cost scan failed; retaining previous cost")
                    self.didLogReadError = true
                }
            }
        }
    }

    struct Scan: Sendable {
        let signature: String
        let cost: GrokDayCost?
        var mirrorSignature: PiSessionCostScanner.GrokSourceSignature?
        var mirrorReport: CostUsageDailyReport?
    }

    nonisolated static func scan(
        home: URL,
        now: Date,
        calendar: Calendar,
        previousSignature: String?,
        mirrors: CostUsageDailyReport) throws -> Scan
    {
        let start = calendar.startOfDay(for: now)
        let log = home.appendingPathComponent("logs/unified.jsonl")
        var parts = [String(start.timeIntervalSince1970)]
        let pricing = CostUsagePricing.GrokResolver()
        parts.append("pricing:\(pricing.fingerprint)")
        let mirror = CostUsageTokenSnapshot.entry(in: mirrors.data, forLocalDayContaining: now, calendar: calendar)
        let unknown = mirror?.modelBreakdowns?.filter { $0.costUSD == nil }.map(\.modelName) ?? []
        parts.append("mirrors:\(mirror?.costUSD ?? 0):\(mirror?.totalTokens ?? 0):\(mirror?.requestCount ?? 0)")
        parts.append("unpriced:\(unknown.sorted().joined(separator: ","))")
        try parts.append(self.fileSignature(log))
        var sessions: [(URL, Bool)] = []
        for cwd in try self.children(home.appendingPathComponent("sessions")) {
            for session in try self.children(cwd) {
                let summary = session.appendingPathComponent("summary.json")
                guard let attributes = try self.attributes(summary) else { continue }
                let modifiedToday = (attributes[.modificationDate] as? Date).map { $0 >= start } ?? false
                sessions.append((session, modifiedToday))
                if modifiedToday { try parts.append(self.fileSignature(summary)) }
            }
        }
        let signature = parts.sorted().joined(separator: "|")
        guard signature != previousSignature else { return Scan(signature: signature, cost: nil) }
        let fixtures = try sessions.map { url, modifiedToday in
            try GrokSessionCost.Session(
                id: url.lastPathComponent,
                summary: self.text(url.appendingPathComponent("summary.json")),
                signals: modifiedToday ? self.text(url.appendingPathComponent("signals.json")) : "{}",
                updates: modifiedToday ? self.text(url.appendingPathComponent("updates.jsonl")) : "")
        }
        var cost = try GrokSessionCost.today(
            unifiedLog: self.text(log),
            sessions: fixtures,
            now: now,
            calendar: calendar,
            pricing: pricing)
        cost.usd += mirror?.costUSD ?? 0
        cost.requestCount += mirror?.requestCount ?? 0
        cost.unpricedModels = Array(Set(cost.unpricedModels + unknown)).sorted()
        return Scan(signature: signature, cost: cost)
    }

    private nonisolated static func children(_ url: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        } catch CocoaError.fileReadNoSuchFile { return [] }
    }

    private nonisolated static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private nonisolated static func fileSignature(_ url: URL) throws -> String {
        guard let attributes = try self.attributes(url) else { return "\(url.path):missing" }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path):\(attributes[.size] ?? 0):\(modified)"
    }

    private nonisolated static func text(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile { return "" }
    }
}
