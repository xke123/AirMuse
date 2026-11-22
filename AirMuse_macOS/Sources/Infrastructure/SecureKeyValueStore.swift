// Sources/Infrastructure/SecureKeyValueStore.swift
// AirMuse macOS – Protocol for secure persistent storage

import Foundation

public protocol SecureKeyValueStore: Sendable {
    func save(_ value: String, forKey key: String) throws
    func load(key: String) throws -> String
    func delete(key: String) throws
    func exists(key: String) -> Bool
}
