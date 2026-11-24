import AppKit
import Foundation
import ImageIO
import Domain

// MARK: - ImageCacheV2

/// Core V2 image cache with `(URL, pixelSize)` request coalescing,
/// off-MainActor CGImageSource downsampling, 50MB memory limit, and 300MB disk LRU budget.
public actor ImageCacheV2 {
    public static let shared = ImageCacheV2()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskDirectoryURL: URL
    private let httpClient: HTTPClient
    private let maxDiskBytes: Int
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    public init(
        httpClient: HTTPClient = HTTPClient(),
        diskDirectoryURL: URL? = nil,
        maxMemoryBytes: Int = 50 * 1024 * 1024,
        maxDiskBytes: Int = 300 * 1024 * 1024
    ) {
        self.httpClient = httpClient
        self.maxDiskBytes = max(1024 * 1024, maxDiskBytes)
        self.memoryCache.totalCostLimit = maxMemoryBytes

        if let custom = diskDirectoryURL {
            self.diskDirectoryURL = custom
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.diskDirectoryURL = caches.appendingPathComponent("AirMuse/ImageCacheV2", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.diskDirectoryURL, withIntermediateDirectories: true)
    }

    public func image(for url: URL, targetPixelSize: Int = 300) async -> NSImage? {
        let key = Self.cacheKey(url: url, pixelSize: targetPixelSize)
        if let mem = memoryCache.object(forKey: key as NSString) {
            return mem
        }

        if let existingTask = inFlight[key] {
            return await existingTask.value
        }

        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadAndDecode(url: url, pixelSize: targetPixelSize, key: key)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    public func diskUsageBytes() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diskDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }
        return files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + size
        }
    }

    public func clearAll() {
        memoryCache.removeAllObjects()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        try? FileManager.default.removeItem(at: diskDirectoryURL)
        try? FileManager.default.createDirectory(at: diskDirectoryURL, withIntermediateDirectories: true)
    }

    // MARK: - Internal Loading & Decoding (Off-MainActor)

    private func loadAndDecode(url: URL, pixelSize: Int, key: String) async -> NSImage? {
        let fileURL = diskDirectoryURL.appendingPathComponent(Self.safeFilename(for: key))
        let fm = FileManager.default

        if fm.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let decoded = Self.downsampleImage(data: data, maxPixelSize: pixelSize) {
            let cost = pixelSize * pixelSize * 4
            memoryCache.setObject(decoded, forKey: key as NSString, cost: cost)
            return decoded
        }

        let req = HTTPRequest(
            method: .get,
            url: url,
            policy: RequestPolicy(
                totalDeadlineSeconds: 12.0,
                attemptTimeoutSeconds: 6.0,
                maxRetries: 1,
                priority: .normal,
                authScope: .publicCatalog(providerID: "image", storefront: "global"),
                deduplicate: true
            )
        )
        guard let resp = try? await httpClient.send(req), !resp.data.isEmpty else {
            return nil
        }

        guard let decoded = Self.downsampleImage(data: resp.data, maxPixelSize: pixelSize) else {
            return nil
        }

        try? resp.data.write(to: fileURL, options: .atomic)
        evictDiskIfNeeded()

        let cost = pixelSize * pixelSize * 4
        memoryCache.setObject(decoded, forKey: key as NSString, cost: cost)
        return decoded
    }

    private func evictDiskIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diskDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var total = 0
        var items: [(url: URL, size: Int, mtime: Date)] = []
        for url in files {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = vals?.fileSize ?? 0
            let mtime = vals?.contentModificationDate ?? .distantPast
            total += size
            items.append((url, size, mtime))
        }
        guard total > maxDiskBytes else { return }

        items.sort { $0.mtime < $1.mtime }
        for item in items {
            if total <= maxDiskBytes { break }
            try? fm.removeItem(at: item.url)
            total -= item.size
        }
    }

    public static func cacheKey(url: URL, pixelSize: Int) -> String {
        "\(url.absoluteString)|\(pixelSize)px"
    }

    private static func safeFilename(for key: String) -> String {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx.img", hash)
    }

    nonisolated private static func downsampleImage(data: Data, maxPixelSize: Int) -> NSImage? {
        let cfData = data as CFData
        guard let source = CGImageSourceCreateWithData(cfData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixelSize)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
