import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class GrokDailyCostCache {
    static let shared = GrokDailyCostCache()
    var today: GrokDayCost?
    var daily: [CostUsageDailyReport.Entry]? {
        didSet {
            guard self.daily != oldValue else { return }
            self.dailyRevision += 1
            self.republishers = self.republishers.filter { $0.value.owner != nil }
            for observer in self.republishers.values {
                observer.republish()
            }
        }
    }

    private(set) var dailyRevision = 0
    @ObservationIgnored private var sessionCache = SessionCache()
    @ObservationIgnored private var republishers: [ObjectIdentifier: Republisher] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var day: Date?
    @ObservationIgnored private var inputSignature: String?
    @ObservationIgnored private var mirrorSignature: PiSessionCostScanner.GrokSourceSignature?
    @ObservationIgnored private var mirrorReport: CostUsageDailyReport?
    @ObservationIgnored private var didLogReadError = false

    private struct Republisher {
        weak var owner: AnyObject?
        let republish: @MainActor () -> Void
    }

    func installRepublisher(for owner: AnyObject, republish: @escaping @MainActor () -> Void) {
        let id = ObjectIdentifier(owner)
        guard self.republishers[id]?.owner == nil else { return }
        self.republishers[id] = Republisher(owner: owner, republish: republish)
    }

    func clearForNewDay(now: Date, calendar: Calendar) {
        let day = calendar.startOfDay(for: now)
        guard self.day != day else { return }
        self.today = nil
        self.daily = nil
        self.inputSignature = nil
        self.day = day
    }

    func refreshIfNeeded(now: Date) {
        guard !TestProcessSafety.isRunning else { return }
        let calendar = Calendar.current
        self.clearForNewDay(now: now, calendar: calendar)
        guard self.task == nil else { return }
        guard self.lastAttempt.map({ now.timeIntervalSince($0) >= 60 }) ?? true
            || self.lastAttempt.map({ !calendar.isDate($0, inSameDayAs: now) }) == true else { return }
        self.lastAttempt = now
        let signature = self.inputSignature
        let previousMirrorSignature = self.mirrorSignature
        let previousMirrorReport = self.mirrorReport
        let sessionCache = self.sessionCache
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
                        let since = calendar.date(
                            byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
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
                            mirrors: mirrors,
                            sessionCache: sessionCache)
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
                self.sessionCache = scan.sessionCache
                if let daily = scan.daily { self.daily = daily }
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
        let daily: [CostUsageDailyReport.Entry]?
        let sessionCache: SessionCache
        var parsedSessionCount = 0
        var mirrorSignature: PiSessionCostScanner.GrokSourceSignature?
        var mirrorReport: CostUsageDailyReport?
    }

    struct SessionCache: Sendable {
        fileprivate var sessions: [String: CachedSession] = [:]
    }

    fileprivate struct CachedSession: Sendable {
        let signature: String
        let session: GrokSessionCost.Session
    }

    nonisolated static func scan(
        home: URL,
        now: Date,
        calendar: Calendar,
        previousSignature: String?,
        mirrors: CostUsageDailyReport,
        sessionCache: SessionCache = .init()) throws -> Scan
    {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let firstDay = GrokLocalSessionScanner.dayKey(for: start, calendar: calendar) ?? ""
        let lastDay = GrokLocalSessionScanner.dayKey(for: today, calendar: calendar) ?? ""
        let mirrors = CostUsageDailyReport(
            data: mirrors.data.filter { $0.date >= firstDay && $0.date <= lastDay }, summary: nil)
        let log = home.appendingPathComponent("logs/unified.jsonl")
        var parts = [String(today.timeIntervalSince1970), calendar.timeZone.identifier]
        let pricing = CostUsagePricing.GrokResolver()
        parts.append("pricing:\(pricing.fingerprint)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let mirrorJSON = try String(data: encoder.encode(mirrors.data), encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        parts.append(mirrorJSON)
        try parts.append(self.fileSignature(log))
        var sessions: [(url: URL, signature: String, includeUsage: Bool)] = []
        for cwd in try self.children(home.appendingPathComponent("sessions")) {
            for session in try self.children(cwd) {
                let summary = session.appendingPathComponent("summary.json")
                guard let attributes = try self.attributes(summary) else { continue }
                let includeUsage = (attributes[.modificationDate] as? Date)
                    .map { $0 >= start && $0 < end } ?? false
                var signature = try self.fileSignature(summary)
                if includeUsage {
                    signature += try "|" + self.fileSignature(session.appendingPathComponent("signals.json"))
                    signature += try "|" + self.fileSignature(session.appendingPathComponent("updates.jsonl"))
                }
                signature += "|\(includeUsage)|\(pricing.fingerprint)"
                sessions.append((session, signature, includeUsage))
                parts.append(signature)
            }
        }
        let signature = parts.sorted().joined(separator: "|")
        guard signature != previousSignature else {
            return Scan(signature: signature, cost: nil, daily: nil, sessionCache: sessionCache)
        }
        var retained = SessionCache()
        var parsedSessionCount = 0
        let fixtures = try sessions.map { entry in
            let path = entry.url.path
            if let cached = sessionCache.sessions[path], cached.signature == entry.signature {
                retained.sessions[path] = cached
                return cached.session
            }
            let session = try GrokSessionCost.Session(
                id: entry.url.lastPathComponent,
                summary: self.text(entry.url.appendingPathComponent("summary.json")),
                signals: entry.includeUsage ? self.text(entry.url.appendingPathComponent("signals.json")) : "{}",
                updates: entry.includeUsage ? self.text(entry.url.appendingPathComponent("updates.jsonl")) : "",
                pricing: pricing)
            retained.sessions[path] = CachedSession(signature: entry.signature, session: session)
            parsedSessionCount += 1
            return session
        }
        let native = try GrokSessionCost.daily(
            unifiedLog: self.text(log),
            sessions: fixtures,
            now: now,
            calendar: calendar,
            days: 30,
            pricing: pricing)
        let mirror = CostUsageTokenSnapshot.entry(in: mirrors.data, forLocalDayContaining: now, calendar: calendar)
        var cost = native[lastDay] ?? GrokDayCost()
        cost.usd += mirror?.costUSD ?? 0
        cost.requestCount += mirror?.requestCount ?? 0
        let unknown = mirror?.modelBreakdowns?.filter { $0.costUSD == nil }.map(\.modelName) ?? []
        cost.unpricedModels = Array(Set(cost.unpricedModels + unknown)).sorted()
        for model in mirror?.modelBreakdowns ?? [] {
            if let usd = model.costUSD { cost.modelUSD[model.modelName, default: 0] += usd }
        }
        return Scan(
            signature: signature,
            cost: cost,
            daily: GrokPricedDaily.entries(native: native, mirrors: mirrors),
            sessionCache: retained,
            parsedSessionCount: parsedSessionCount)
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
