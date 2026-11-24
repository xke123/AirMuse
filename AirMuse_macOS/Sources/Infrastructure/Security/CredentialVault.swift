import Foundation
import Domain

// MARK: - CredentialVault

/// Actor-isolated credential vault conforming to `CredentialVaultProtocol`.
/// Stores scoped credentials (`client` vs `user`, partitioned by provider & accountID)
/// in the injected `SecureKeyValueStore` (Keychain or POSIX-0600 AppPrivateStore),
/// and supports non-destructive migration from legacy flat keys.
public actor CredentialVault: CredentialVaultProtocol {
    private let store: any SecureKeyValueStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(store: any SecureKeyValueStore) {
        self.store = store
    }

    public func load(providerID: String, accountID: String?, kind: CredentialKind) async throws -> CredentialRecord? {
        let key = Self.storageKey(providerID: providerID, accountID: accountID, kind: kind)
        do {
            let raw = try store.load(key: key)
            guard let data = raw.data(using: .utf8) else {
                throw CoreError.storage("Credential encoding invalid for \(key)")
            }
            return try decoder.decode(CredentialRecord.self, from: data)
        } catch KeychainError.itemNotFound {
            return nil
        } catch let err as CoreError {
            throw err
        } catch {
            throw CoreError.storage(error.localizedDescription)
        }
    }

    public func save(_ record: CredentialRecord, providerID: String, accountID: String?) async throws {
        let key = Self.storageKey(providerID: providerID, accountID: accountID, kind: record.kind)
        do {
            let data = try encoder.encode(record)
            guard let raw = String(data: data, encoding: .utf8) else {
                throw CoreError.storage("Failed to encode credential record")
            }
            try store.save(raw, forKey: key)
        } catch let err as CoreError {
            throw err
        } catch {
            throw CoreError.storage(error.localizedDescription)
        }
    }

    public func delete(providerID: String, accountID: String?, kind: CredentialKind) async throws {
        let key = Self.storageKey(providerID: providerID, accountID: accountID, kind: kind)
        do {
            try store.delete(key: key)
        } catch KeychainError.itemNotFound {
            return
        } catch {
            throw CoreError.storage(error.localizedDescription)
        }
    }

    public func clearAccountCredentials(providerID: String, accountID: String) async throws {
        try await delete(providerID: providerID, accountID: accountID, kind: .user)
    }

    /// Migrates a legacy flat-key credential into the scoped vault if the scoped entry
    /// does not already exist. Never deletes the legacy key if saving fails.
    public func migrateLegacyKeyIfNeeded(
        legacyKey: String,
        providerID: String,
        accountID: String?,
        kind: CredentialKind
    ) async throws -> Bool {
        if try await load(providerID: providerID, accountID: accountID, kind: kind) != nil {
            return false
        }
        let legacyVal: String
        do {
            legacyVal = try store.load(key: legacyKey)
        } catch KeychainError.itemNotFound {
            return false
        } catch {
            throw CoreError.storage(error.localizedDescription)
        }
        let trimmed = legacyVal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let record = CredentialRecord(kind: kind, value: trimmed)
        try await save(record, providerID: providerID, accountID: accountID)
        return true
    }

    public static func storageKey(providerID: String, accountID: String?, kind: CredentialKind) -> String {
        let acct = (accountID?.isEmpty == false) ? accountID! : "_global_"
        return "v2.cred.\(providerID).\(acct).\(kind.rawValue)"
    }
}
