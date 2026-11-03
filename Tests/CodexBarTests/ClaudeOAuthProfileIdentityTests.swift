import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeOAuthProfileIdentityTests {
    @Test
    func `requested OAuth profile keeps its email in the published identity`() async throws {
        let snapshot = try await self.fetch { token in
            #expect(token == "fixture-oauth-token")
            return OAuthProfileResponse(emailAddress: "oauth@example.com", organizationUuid: "fixture-org")
        }
        let published = ClaudeOAuthFetchStrategy._snapshotForTesting(from: snapshot)
        #expect(snapshot.accountEmail == "oauth@example.com")
        #expect(published.identity?.accountEmail == "oauth@example.com")
        #expect(published.identity?.providerID == .claude)
        #expect(snapshot.accountID != nil)
        #expect(snapshot.primary?.usedPercent == 17)
        #expect(snapshot.accountOrganization == nil)
    }

    @Test
    func `profile email does not require enough fields to establish widget ownership`() async throws {
        let snapshot = try await self.fetch { _ in
            OAuthProfileResponse(emailAddress: "oauth@example.com", organizationUuid: nil)
        }
        #expect(snapshot.accountEmail == "oauth@example.com")
        #expect(snapshot.accountID == nil)
        #expect(snapshot.primary?.usedPercent == 17)
    }

    @Test
    func `failed optional profile leaves successful OAuth usage available`() async throws {
        let snapshot = try await self.fetch { _ in throw URLError(.timedOut) }
        #expect(snapshot.accountEmail == nil)
        #expect(snapshot.accountID == nil)
        #expect(snapshot.primary?.usedPercent == 17)
    }

    @Test
    func `ordinary refresh caches same-token email without verifying widget ownership`() async throws {
        let cache = ClaudeOAuthDisplayProfileCache()
        let calls = ProfileCalls()
        let profile: @Sendable (String) async throws -> OAuthProfileResponse = { token in
            await calls.append(token)
            return OAuthProfileResponse(emailAddress: "oauth@example.com", organizationUuid: "fixture-org")
        }
        _ = try await self.fetch(includeAccountIdentity: false, cache: cache, profile: profile)
        await cache.finishPendingForTesting()
        let snapshot = try await self.fetch(includeAccountIdentity: false, cache: cache, profile: profile)
        #expect(snapshot.accountEmail == "oauth@example.com")
        #expect(snapshot.accountID == nil)
        #expect(snapshot.primary?.usedPercent == 17)
        #expect(await calls.tokens == ["fixture-oauth-token"])
    }

    @Test
    func `credential changes cannot borrow another tokens cached email`() async throws {
        let cache = ClaudeOAuthDisplayProfileCache()
        let calls = ProfileCalls()
        let profile: @Sendable (String) async throws -> OAuthProfileResponse = { token in
            await calls.append(token)
            return OAuthProfileResponse(emailAddress: "\(token)@example.com", organizationUuid: nil)
        }
        for token in ["first", "second", "first"] {
            _ = try await self.fetch(includeAccountIdentity: false, cache: cache, token: token, profile: profile)
            await cache.finishPendingForTesting()
            let snapshot = try await self.fetch(
                includeAccountIdentity: false, cache: cache, token: token, profile: profile)
            #expect(snapshot.accountEmail == "\(token)@example.com")
            #expect(snapshot.accountID == nil)
        }
        #expect(await calls.tokens == ["first", "second"])
    }

    @Test
    func `failed display lookup retains usage and does not retry the same credential`() async throws {
        let cache = ClaudeOAuthDisplayProfileCache()
        let calls = ProfileCalls()
        let profile: @Sendable (String) async throws -> OAuthProfileResponse = { token in
            await calls.append(token)
            throw URLError(.timedOut)
        }
        let first = try await self.fetch(includeAccountIdentity: false, cache: cache, profile: profile)
        #expect(first.primary?.usedPercent == 17)
        await cache.finishPendingForTesting()
        let next = try await self.fetch(includeAccountIdentity: false, cache: cache, profile: profile)
        #expect(next.primary?.usedPercent == 17)
        #expect(next.accountEmail == nil)
        #expect(next.accountID == nil)
        #expect(await calls.tokens == ["fixture-oauth-token"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `stalled display lookup returns usage before its deadline and fails soft at timeout`() async throws {
        let cache = ClaudeOAuthDisplayProfileCache()
        let response = ProfilePause()
        let deadline = ProfilePause()
        let sleep: @Sendable (Duration) async throws -> Void = { _ in await deadline.wait() }
        try await BoundedTaskJoinTiming.$sleep.withValue(sleep) {
            let snapshot = try await self.fetch(includeAccountIdentity: false, cache: cache) { _ in
                await response.wait()
                return OAuthProfileResponse(emailAddress: "too-late@example.com", organizationUuid: nil)
            }
            #expect(snapshot.primary?.usedPercent == 17)
            #expect(snapshot.accountEmail == nil)
            await deadline.open()
            await cache.finishPendingForTesting()
            await response.open()
            let next = try await self.fetch(includeAccountIdentity: false, cache: cache) { _ in
                Issue.record("Timed-out credentials must not retry")
                throw URLError(.timedOut)
            }
            #expect(next.accountEmail == nil)
            #expect(next.primary?.usedPercent == 17)
        }
    }

    @MainActor
    @Test(arguments: [false, true])
    func `renewed credential profile continues the same account history`(includeAccountIdentity: Bool) async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let cache = ClaudeOAuthDisplayProfileCache()
        let profile: @Sendable (String) async throws -> OAuthProfileResponse = { _ in
            OAuthProfileResponse(emailAddress: "same-account@example.com", organizationUuid: "fixture-org")
        }
        var owners: [String] = []
        for (index, token) in ["before-renewal", "after-renewal"].enumerated() {
            _ = try await self.fetch(
                includeAccountIdentity: includeAccountIdentity,
                cache: cache,
                token: token,
                refreshToken: "refresh-\(token)",
                profile: profile)
            await cache.finishPendingForTesting()
            let snapshot = try await self.fetch(
                includeAccountIdentity: includeAccountIdentity,
                cache: cache,
                token: token,
                refreshToken: "refresh-\(token)",
                profile: profile)
            let usage = ClaudeOAuthFetchStrategy._snapshotForTesting(from: snapshot)
            try owners.append(#require(snapshot.oauthHistoryOwnerIdentifier))
            if index == 1 {
                await store.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: usage,
                    claudeOAuthHistoryOwnerIdentifier: snapshot.oauthHistoryOwnerIdentifier,
                    claudeOAuthKeychainCredentialUnavailable: true,
                    isClaudeOAuthSample: true,
                    now: Date(timeIntervalSince1970: 1_700_000_000 + 1800))
                #expect(store.planUtilizationHistory[.claude]?.accounts.count == 1)
            }
            await store.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: usage,
                claudeOAuthHistoryOwnerIdentifier: snapshot.oauthHistoryOwnerIdentifier,
                claudeOAuthProfileIdentity: UsageStore.legacyClaudePlanUtilizationEmailAccountKey(snapshot: usage),
                claudeOAuthKeychainCredentialUnavailable: true,
                isClaudeOAuthSample: true,
                now: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 3600)))
        }
        #expect(owners[0] != owners[1])
        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.accounts.count == 1)
        #expect(buckets.histories(for: buckets.preferredAccountKey).first?.entries.count == 2)
        let encoded = try JSONEncoder().encode(UsageStore.loadClaudeOAuthAccountUuidMap(
            from: store.settings.userDefaults))
        let persisted = try #require(String(data: encoded, encoding: .utf8))
        #expect(!persisted.contains("before-renewal"))
        #expect(!persisted.contains("after-renewal"))
        #expect(!persisted.contains("same-account@example.com"))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            claudeOAuthHistoryOwnerIdentifier: owners[1],
            claudeOAuthKeychainCredentialUnavailable: true,
            isClaudeOAuthSample: true,
            now: Date(timeIntervalSince1970: 1_700_000_000 + 7200))
        let continued = try #require(store.planUtilizationHistory[.claude])
        #expect(continued.accounts.count == 1)
        #expect(continued.histories(for: continued.preferredAccountKey).first?.entries.count == 3)
    }

    private func fetch(
        includeAccountIdentity: Bool = true,
        cache: ClaudeOAuthDisplayProfileCache = ClaudeOAuthDisplayProfileCache(),
        token: String = "fixture-oauth-token",
        refreshToken: String? = nil,
        profile: @escaping @Sendable (String) async throws -> OAuthProfileResponse) async throws -> ClaudeUsageSnapshot
    {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            includeAccountIdentity: includeAccountIdentity)
        let credentials: @Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in
            ClaudeOAuthCredentials(
                accessToken: token,
                refreshToken: refreshToken,
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: "claude_pro")
        }
        let usage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { _, _ in
            try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data("""
            {"five_hour":{"utilization":17}}
            """.utf8))
        }
        return try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(credentials) {
            try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(usage) {
                try await ClaudeUsageFetcher.$fetchOAuthProfileOverride.withValue(profile) {
                    try await ClaudeUsageFetcher.$displayProfileCache.withValue(cache) {
                        try await fetcher.loadLatestUsage()
                    }
                }
            }
        }
    }
}

private actor ProfileCalls {
    var tokens: [String] = []
    func append(_ token: String) { self.tokens.append(token) }
}

private actor ProfilePause {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        self.waiters.forEach { $0.resume() }
        self.waiters.removeAll()
    }
}
