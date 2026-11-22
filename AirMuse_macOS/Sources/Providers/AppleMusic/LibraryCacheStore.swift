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
        var count = 0
        for (k, v) in categories {
            stringKeyed[String(k)] = v
            count += v.count
        }
        let payload = stringKeyed
        let targetURL = self.cacheURL
        let tabCount = categories.keys.count
        let totalCats = count

        queue.async {
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: targetURL, options: .atomic)
                AppLogger.shared.log(
                    category: .cache,
                    level: .info,
                    message: "【缓存写入】分类与专区已持久化至本地磁盘",
                    details: "标签数: \(tabCount), 专区总数: \(totalCats), 大小: \(data.count) 字节, 路径: \(targetURL.lastPathComponent)"
                )
            } catch {
                AppLogger.shared.log(category: .cache, level: .warn, message: "分类缓存写入失败: \(error.localizedDescription)")
            }
        }
    }

    /// Load cached categories synchronously on startup
    public func load() -> [Int: [AmpCategory]]? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            AppLogger.shared.log(category: .cache, level: .info, message: "【缓存未命中】未发现本地分类缓存文件 (\(cacheURL.lastPathComponent))")
            return nil
        }
        do {
            let data = try Data(contentsOf: cacheURL)
            let decoded = try JSONDecoder().decode([String: [AmpCategory]].self, from: data)
            var result: [Int: [AmpCategory]] = [:]
            var totalCats = 0
            for (k, v) in decoded {
                if let intKey = Int(k) {
                    result[intKey] = v
                    totalCats += v.count
                }
            }
            AppLogger.shared.log(
                category: .cache,
                level: .info,
                message: "【缓存命中】成功载入本地分类与专区缓存",
                details: "标签数: \(result.keys.count), 专区总数: \(totalCats), 大小: \(data.count) 字节"
            )
            return result
        } catch {
            AppLogger.shared.log(category: .cache, level: .warn, message: "分类缓存解析失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// Clear cached catalog on logout or account switch
    public func clear() {
        let targetURL = self.cacheURL
        queue.async {
            try? FileManager.default.removeItem(at: targetURL)
            AppLogger.shared.log(category: .cache, level: .info, message: "【缓存清除】已清空本地分类与专区磁盘缓存")
        }
    }
}
