import Foundation

enum PiSessionCostCacheIO {
    /// Artifact schema version. Pricing changes are tracked separately by `pricingKey`.
    /// v11 retains compact entry archives and validates older data through a streaming source rebuild.
    private static let artifactVersion = 11

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("pi-sessions-v\(Self.artifactVersion).json", isDirectory: false)
    }

    static func load(cacheRoot: URL? = nil) -> PiSessionCostCache {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard let loaded: (PiSessionCostCache, [String: PiSessionFileUsage]) = try? CostUsageClaudeFragments.shared
            .load(at: url, legacy: { _ in throw CocoaError(.fileReadCorruptFile) })
        else { return PiSessionCostCache(version: Self.artifactVersion) }
        var cache: PiSessionCostCache = loaded.0
        guard cache.version == Self.artifactVersion else { return PiSessionCostCache(version: Self.artifactVersion) }
        cache.files = loaded.1
        return cache
    }

    static func save(
        cache: PiSessionCostCache,
        cacheRoot: URL? = nil,
        calendar: Calendar = .current)
    {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        var header = cache
        header.timeZoneIdentifier = calendar.timeZone.identifier
        header.files = [:]
        _ = try? CostUsageClaudeFragments.shared.save(
            header: header,
            values: cache.files,
            at: url,
            shardByFile: true,
            unchangedHeader: { previous, current in
                var previous = previous
                previous.lastScanUnixMs = current.lastScanUnixMs
                return previous == current
            })
    }
}

struct PiSessionCostCache: Codable, Equatable {
    var version: Int
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?
    var timeZoneIdentifier: String?
    var pricingKey: String?
    var sessionRootsFingerprint: String?
    var daysByProvider: [String: [String: [String: PiPackedUsage]]] = [:]
    var files: [String: PiSessionFileUsage] = [:]

    init(version: Int = 11) {
        self.version = version
    }
}

struct PiSessionFileUsage: Codable, Equatable {
    var mtimeUnixMs: Int64
    var size: Int64
    var parsedBytes: Int64
    var fileIdentity: String?
    var sessionID: String?
    var lastModelContext: PiModelContext?
    var contributions: [String: [String: [String: PiPackedUsage]]]
    var unkeyedContributions: [String: [String: [String: PiPackedUsage]]]
    var entryArchive: PiSessionEntryUsageArchive
    var unsupportedAssistantDayKeys: Set<String>
    var hasUndatedUnsupportedAssistant: Bool

    var entryUsages: [String: PiSessionEntryUsage] {
        get throws { try self.entryArchive.decode() }
    }

    init(
        mtimeUnixMs: Int64,
        size: Int64,
        parsedBytes: Int64,
        fileIdentity: String? = nil,
        sessionID: String? = nil,
        lastModelContext: PiModelContext?,
        contributions: [String: [String: [String: PiPackedUsage]]],
        unkeyedContributions: [String: [String: [String: PiPackedUsage]]] = [:],
        entryUsages: [String: PiSessionEntryUsage] = [:],
        unsupportedAssistantDayKeys: Set<String> = [],
        hasUndatedUnsupportedAssistant: Bool = false) throws
    {
        self.mtimeUnixMs = mtimeUnixMs
        self.size = size
        self.parsedBytes = parsedBytes
        self.fileIdentity = fileIdentity
        self.sessionID = sessionID
        self.lastModelContext = lastModelContext
        self.contributions = contributions
        self.unkeyedContributions = unkeyedContributions
        self.entryArchive = try PiSessionEntryUsageArchive(entries: entryUsages)
        self.unsupportedAssistantDayKeys = unsupportedAssistantDayKeys
        self.hasUndatedUnsupportedAssistant = hasUndatedUnsupportedAssistant
    }

    var requiresFullReparseOnChange: Bool {
        self.hasUndatedUnsupportedAssistant || !self.unsupportedAssistantDayKeys.isEmpty ||
            self.contributions.contains { provider, days in
                // Standalone backends can be intentionally unpriced; catalog changes already reparse them.
                guard provider != UsageProvider.pi.rawValue else { return false }
                return days.values.contains { models in
                    models.values.contains { ($0.usageSampleCount ?? 0) > $0.costSampleCount }
                }
            }
    }
}

struct PiSessionEntryUsage: Codable, Equatable {
    var providerRawValue: String
    var dayKey: String
    var modelName: String
    var usage: PiPackedUsage
}

extension PiSessionEntryUsage {
    init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        try self.init(
            providerRawValue: values.decode(String.self),
            dayKey: values.decode(String.self),
            modelName: values.decode(String.self),
            usage: PiPackedUsage(
                inputTokens: values.decode(Int.self),
                cacheReadTokens: values.decode(Int.self),
                cacheWriteTokens: values.decode(Int.self),
                outputTokens: values.decode(Int.self),
                totalTokens: values.decode(Int.self),
                costNanos: values.decode(Int64.self),
                costSampleCount: values.decode(Int.self),
                usageSampleCount: values.decodeIfPresent(Int.self)))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(self.providerRawValue)
        try values.encode(self.dayKey)
        try values.encode(self.modelName)
        try values.encode(self.usage.inputTokens)
        try values.encode(self.usage.cacheReadTokens)
        try values.encode(self.usage.cacheWriteTokens)
        try values.encode(self.usage.outputTokens)
        try values.encode(self.usage.totalTokens)
        try values.encode(self.usage.costNanos)
        try values.encode(self.usage.costSampleCount)
        try values.encode(self.usage.usageSampleCount)
    }
}

struct PiSessionEntryUsageArchive: Codable, Equatable {
    let bytes: Data
    let contributions: [String: [String: [String: PiPackedUsage]]]
    private enum CodingKeys: CodingKey { case bytes, contributions }

    init(entries: [String: PiSessionEntryUsage]) throws {
        self.contributions = try Self.aggregate(entries)
        self.bytes = try autoreleasepool {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try encoder.encode(Records(entries: entries))
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bytes = try container.decode(Data.self, forKey: .bytes)
        self.contributions = try container.decode(
            [String: [String: [String: PiPackedUsage]]].self, forKey: .contributions)
        try autoreleasepool {
            guard try Self.aggregate(self.decode()) == self.contributions else {
                throw CocoaError(.coderInvalidValue)
            }
        }
    }

    func decode() throws -> [String: PiSessionEntryUsage] {
        PiSessionCostScanner.entryArchiveDecodeObserverForTesting?()
        return try PropertyListDecoder().decode(Records.self, from: self.bytes).entries
    }

    private static func aggregate(_ entries: [String: PiSessionEntryUsage]) throws
        -> [String: [String: [String: PiPackedUsage]]]
    {
        var days: [String: [String: [String: PiPackedUsage]]] = [:]
        for entry in entries.values {
            guard PiSessionCostScanner.applyContributions(daysByProvider: &days, contributions: [
                entry.providerRawValue: [entry.dayKey: [entry.modelName: entry.usage]],
            ]) else { throw CocoaError(.coderInvalidValue) }
        }
        return days
    }

    private struct Records: Codable {
        let entries: [String: PiSessionEntryUsage]

        init(entries: [String: PiSessionEntryUsage]) { self.entries = entries }

        init(from decoder: any Decoder) throws {
            var records = try decoder.unkeyedContainer()
            var entries: [String: PiSessionEntryUsage] = [:]
            while !records.isAtEnd {
                let id = try records.decode(String.self)
                let entry = try records.decode(PiSessionEntryUsage.self)
                guard entries.updateValue(entry, forKey: id) == nil else {
                    throw CocoaError(.coderInvalidValue)
                }
            }
            self.entries = entries
        }

        func encode(to encoder: any Encoder) throws {
            var records = encoder.unkeyedContainer()
            for id in self.entries.keys.sorted() {
                try records.encode(id)
                try records.encode(self.entries[id]!)
            }
        }
    }
}

struct PiModelContext: Codable, Equatable {
    var providerRawValue: String
    var modelName: String
    var isUnsupportedBackend: Bool = false
}

struct PiPackedUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var outputTokens: Int = 0
    var totalTokens: Int = 0
    var costNanos: Int64 = 0
    var costSampleCount: Int = 0
    var usageSampleCount: Int?

    var isZero: Bool {
        self.inputTokens == 0
            && self.cacheReadTokens == 0
            && self.cacheWriteTokens == 0
            && self.outputTokens == 0
            && self.totalTokens == 0
            && self.costNanos == 0
            && self.costSampleCount == 0
            && (self.usageSampleCount ?? 0) == 0
    }
}
