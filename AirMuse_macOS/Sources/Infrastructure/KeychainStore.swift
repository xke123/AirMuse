// Sources/Infrastructure/KeychainStore.swift
// AirMuse macOS – Secure Keychain storage for OAuth tokens, etc.

import Foundation
import Security

// MARK: - Errors

public enum KeychainError: Error, Sendable {
    case itemNotFound
    case duplicateItem
    case invalidData
    case unexpectedStatus(OSStatus)
}

// MARK: - KeychainStore

/// Thread-safe Keychain wrapper. All operations are synchronous but cheap.
public struct KeychainStore: Sendable {

    private let service: String

    public init(service: String = "com.airmuse.keychain") {
        self.service = service
    }

    // MARK: - Public API

    /// Save a string value to Keychain (creates or updates).
    public func save(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        // Try update first
        let query = baseQuery(key: key)
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            // Insert
            var newItem = baseQuery(key: key)
            newItem[kSecValueData] = data
            newItem[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Load a string value from Keychain.
    public func load(key: String) throws -> String {
        var query = baseQuery(key: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return string
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Delete a Keychain item.
    public func delete(key: String) throws {
        let query = baseQuery(key: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Check whether a key exists.
    public func exists(key: String) -> Bool {
        var query = baseQuery(key: key)
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Helpers

    private func baseQuery(key: String) -> [CFString: Any] {
        [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }
}
