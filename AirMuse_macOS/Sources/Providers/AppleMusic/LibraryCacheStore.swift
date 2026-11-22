// Sources/Providers/AppleMusic/LibraryCacheStore.swift
// AirMuse macOS – Persistent local disk cache for Apple Music editorial & catalog categories
// Ported from AirMuse_Remastered airmuse_catalog_v3 IndexedDB caching
// Swift 6 strict concurrency

import Foundation
import Infrastructure

/// Thread-safe persistent disk cache storing category datasets across application restarts.
public final class LibraryCacheStore: @unchecked Sendable {
    public static let shared = LibraryCacheStore()

    private let cacheURL: URL
    private let queue = DispatchQueue(label: "com.airmuse.librarycache", qos: .utility)

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("AirMuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("catalog_categories_v1.json")
    }

    /// Save loaded tab categories asynchronously to disk
    public func save(categories: [Int: [AmpCategory]]) {
        var stringKeyed: [String: [AmpCategory]] = [:]
        for (k, v) in categories {
            stringKeyed[String(k)] = v
        }
        let payload = stringKeyed
        let targetURL = self.cacheURL

        queue.async {
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: targetURL, options: .atomic)
            } catch {
                AppLogger.shared.log(category: .error, level: .warn, message: "分类缓存写入失败: \(error.localizedDescription)")
            }
        }
    }

    /// Load cached categories synchronously on startup
    public func load() -> [Int: [AmpCategory]]? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: cacheURL)
            let decoded = try JSONDecoder().decode([String: [AmpCategory]].self, from: data)
            var result: [Int: [AmpCategory]] = [:]
            for (k, v) in decoded {
                if let intKey = Int(k) {
                    result[intKey] = v
                }
            }
            return result
        } catch {
            AppLogger.shared.log(category: .error, level: .warn, message: "分类缓存解析失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// Clear cached catalog on logout or account switch
    public func clear() {
        let targetURL = self.cacheURL
        queue.async {
            try? FileManager.default.removeItem(at: targetURL)
        }
    }
}
