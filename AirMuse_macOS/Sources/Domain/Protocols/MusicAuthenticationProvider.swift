import Foundation

// MARK: - MusicAuthenticationProvider

/// Handles sign-in / sign-out for a music provider.
public protocol MusicAuthenticationProvider: Sendable {
    var providerID: String { get }
    var isAuthenticated: Bool { get async }

    func getAccount() async throws -> MusicAccount
    func authenticate() async throws
    func signOut() async throws
    func currentAccount() async -> MusicAccount?
}

extension MusicAuthenticationProvider {
    public func getAccount() async throws -> MusicAccount {
        if let account = await currentAccount() {
            return account
        }
        return MusicAccount(displayName: nil, source: .unknown, isAuthenticated: await isAuthenticated)
    }
    public func currentAccount() async -> MusicAccount? {
        MusicAccount(displayName: nil, source: .unknown, isAuthenticated: await isAuthenticated)
    }
}
