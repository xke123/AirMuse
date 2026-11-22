// Sources/Infrastructure/AppPrivateStore.swift
// AirMuse macOS – Private sandboxed key-value store with hardware Data Protection and 0600 POSIX permissions.
// Stores non-critical session tokens and storefront IDs isolated to the user's private application support directory,
// completely eliminating macOS Keychain ACL / code signature prompts for ad-hoc and locally compiled builds.

import Foundation

public final class AppPrivateStore: SecureKeyValueStore, @unchecked Sendable {
    public static let shared = AppPrivateStore()

    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [String: String]?

    public init(directoryURL: URL? = nil, fileName: String = "session_vault.json") {
        let dir: URL
        if let directoryURL {
            dir = directoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
            dir = appSupport.appendingPathComponent("AirMuse/Security", isDirectory: true)
        }

        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: 0o700 // rwx------ only current user
            ]
        )
        self.fileURL = dir.appendingPathComponent(fileName)
    }

    // MARK: - SecureKeyValueStore Protocol

    public func save(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var dict = loadDictUnsafe()
        dict[key] = value
        try writeDictUnsafe(dict)
        cache = dict
    }

    public func load(key: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let dict = loadDictUnsafe()
        guard let value = dict[key], !value.isEmpty else {
            throw KeychainError.itemNotFound
        }
        return value
    }

    public func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var dict = loadDictUnsafe()
        guard dict.removeValue(forKey: key) != nil else { return }
        try writeDictUnsafe(dict)
        cache = dict
    }

    public func exists(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let dict = loadDictUnsafe()
        return dict[key] != nil
    }

    // MARK: - Internal Helpers

    private func loadDictUnsafe() -> [String: String] {
        if let cache {
            return cache
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = [:]
            return [:]
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let dict = try JSONDecoder().decode([String: String].self, from: data)
            cache = dict
            return dict
        } catch {
            cache = [:]
            return [:]
        }
    }

    private func writeDictUnsafe(_ dict: [String: String]) throws {
        let data = try JSONEncoder().encode(dict)
        // Atomic write with system data protection (encrypted on disk when device is locked)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        // Explicitly enforce POSIX 0600 (rw-------: owner-only read & write)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
