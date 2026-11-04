import CodexBarCore
import Foundation

/// Credential failures only. Never infer authentication from an arbitrary message containing "token" or "login".
enum ProviderCredentialFailure {
    static func isAuthenticationFailure(_ error: Error) -> Bool {
        switch error {
        case let error as ProviderFetchClassifiedError:
            error.kind == .authenticationExpired || error.kind == .missingCredential
        case KimiAPIError.invalidToken, KimiAPIError.invalidAPIKey,
             KimiAPIError.expiredCodeCredential, KimiAPIError.invalidCodeCredential,
             DoubaoUsageError.arkcliAuthenticationRequired,
             AlibabaTokenPlanUsageError.loginRequired, AlibabaTokenPlanUsageError.invalidCredentials,
             ClaudeOAuthFetchError.unauthorized, CodexOAuthFetchError.unauthorized,
             CodexTokenRefresher.RefreshError.expired, CodexTokenRefresher.RefreshError.revoked,
             CodexTokenRefresher.RefreshError.reused,
             CodexOAuthCredentialsError.nativeRefreshRequired, CodexOAuthCredentialsError.readOnlySource,
             AugmentStatusProbeError.notLoggedIn, AugmentStatusProbeError.sessionExpired,
             AugmentStatusProbeError.noSessionCookie:
            true
        case let error as ClaudeOAuthCredentialsError:
            switch error {
            case .missingOAuth, .missingAccessToken, .notFound, .noRefreshToken: true
            case let .refreshFailed(message):
                self.isRejectedRefresh(message)
            default: false
            }
        case let ClaudeUsageError.oauthFailed(message):
            // This legacy wrapper erases the underlying type; recognize only owned, stable auth messages.
            (message.hasPrefix("Claude OAuth token refresh failed:") && self.isRejectedRefresh(message)) ||
                message == ClaudeOAuthFetchError.unauthorized.localizedDescription ||
                message == ClaudeOAuthCredentialsError.notFound.localizedDescription ||
                message == ClaudeOAuthCredentialsError.noRefreshToken.localizedDescription ||
                message.hasPrefix("Claude OAuth token expired") ||
                message.hasPrefix("Claude OAuth token is still unavailable after delegated Claude CLI refresh.")
        default:
            false
        }
    }

    static func isSignInFailure(_ error: Error) -> Bool {
        switch error {
        case ClaudeStatusProbeError.authenticationFailed,
             ClaudeWebAPIFetcher.FetchError.noSessionKeyFound,
             ClaudeWebAPIFetcher.FetchError.noDesktopSessionKeyFound,
             ClaudeWebAPIFetcher.FetchError.invalidSessionKey,
             ClaudeWebAPIFetcher.FetchError.unauthorized,
             CodexOAuthCredentialsError.notFound, CodexOAuthCredentialsError.missingTokens,
             GrokCredentialsError.notFound, GrokCredentialsError.missingTokens:
            true
        case let error as GrokWebBillingError:
            error.isSignInFailure
        case let error as GrokRPCError:
            error.isSignInFailure
        default:
            self.isAuthenticationFailure(error)
        }
    }

    private static func isRejectedRefresh(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("invalid_grant") || normalized.contains("invalid refresh token")
    }
}

struct ProviderAuthenticationFailure: Equatable {
    let message: String
    let publicationRevision: UsageStore.ProviderPublicationRevision
}

extension UsageStore {
    func recordAuthenticationOutcome(provider: UsageProvider, result: Result<ProviderFetchResult, Error>) {
        if case let .failure(error) = result, ProviderCredentialFailure.isSignInFailure(error) {
            self.authenticationFailures[provider.instanceID] = ProviderAuthenticationFailure(
                message: error.localizedDescription,
                publicationRevision: self.providerPublicationRevision(for: provider))
        } else {
            self.authenticationFailures[provider.instanceID] = nil
        }
    }

    func authenticationFailure(for provider: UsageProvider) -> String? {
        guard let failure = self.authenticationFailures[provider.instanceID],
              failure.publicationRevision == self.providerPublicationRevision(for: provider) else { return nil }
        return failure.message
    }
}
