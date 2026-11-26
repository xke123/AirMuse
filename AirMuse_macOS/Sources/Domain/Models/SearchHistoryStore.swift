import Foundation

// MARK: - SearchHistoryStore

/// Persists the most recent search queries (up to 5) with deduplication, single-item removal, and clear-all support.
@MainActor
public final class SearchHistoryStore {

    public static let defaultMaxCount = 5
    public static let defaultStorageKey = "AirMuse_SearchHistory_v1"

    private let defaults: UserDefaults
    private let storageKey: String
    public let maxCount: Int

    public private(set) var items: [String]

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = SearchHistoryStore.defaultStorageKey,
        maxCount: Int = SearchHistoryStore.defaultMaxCount
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maxCount = max(1, maxCount)
        let saved = defaults.stringArray(forKey: storageKey) ?? []
        self.items = Array(saved.prefix(self.maxCount))
    }

    public func add(_ rawQuery: String) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        items.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        items.insert(trimmed, at: 0)
        if items.count > maxCount {
            items = Array(items.prefix(maxCount))
        }
        persist()
    }

    public func remove(_ query: String) {
        items.removeAll { $0 == query }
        persist()
    }

    public func clearAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(items, forKey: storageKey)
    }
}
