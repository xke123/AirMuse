// Sources/Infrastructure/ImageCache.swift
// AirMuse macOS – Album artwork image cache (memory + disk, ≤50 MB memory cap)

import AppKit
import CryptoKit
import Foundation

// MARK: - Cache Key

public struct ImageCacheKey: Hashable, Sendable {
    public let url: URL
    public let size: CGSize      // decoded pixel dimensions

    public init(url: URL, size: CGSize) {
        self.url = url
        self.size = size
    }

    /// A deterministic SHA-256 string key for disk storage across app launches.
    public var diskKey: String {
        let raw = "\(url.absoluteString)|\(Int(size.width))x\(Int(size.height))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CachedImage (NSCache entry)

private final class CachedImage: NSObject {
    let image: NSImage
    let byteSize: Int
    init(image: NSImage, byteSize: Int) {
        self.image = image
        self.byteSize = byteSize
    }
}

// MARK: - ImageCache Actor

@MainActor
public final class ImageCache: Sendable {

    public static let shared = ImageCache()

    // ── Memory cache ───────────────────────────────────────────────────────
    private let memoryCache = NSCache<NSString, CachedImage>()
    private let memoryLimitBytes = 50 * 1024 * 1024    // 50 MB

    // ── Disk cache directory ───────────────────────────────────────────────
    private let diskCacheURL: URL

    // ── In-flight tasks ────────────────────────────────────────────────────
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    // ── URLSession ─────────────────────────────────────────────────────────
    private let session: URLSession

    public init() {
        memoryCache.totalCostLimit = memoryLimitBytes

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = caches.appendingPathComponent("AirMuse/ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Fetch image at url, decoded to `size` pixels. Returns cached image immediately if available.
    public func image(for url: URL, size: CGSize) async -> NSImage? {
        let key = ImageCacheKey(url: url, size: size)

        // 1. Memory hit
        if let cached = memoryCache.object(forKey: key.diskKey as NSString) {
            return cached.image
        }

        // 2. Disk hit
        if let img = loadFromDisk(key: key) {
            storeInMemory(image: img, for: key)
            return img
        }

        // 3. Coalesce in-flight network requests
        if let existing = inflight[url] {
            let raw = await existing.value
            return raw.flatMap { decoded(image: $0, size: size) }
        }

        let task = Task<NSImage?, Never> {
            do {
                let (data, _) = try await session.data(from: url)
                return NSImage(data: data)
            } catch {
                return nil
            }
        }
        inflight[url] = task
        defer { inflight[url] = nil }

        guard let raw = await task.value else { return nil }
        guard let img = decoded(image: raw, size: size) else { return nil }

        storeInMemory(image: img, for: key)
        saveToDisk(image: img, key: key)
        return img
    }

    /// Remove all cached images.
    public func clearAll() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    // MARK: - Private Helpers

    private func decoded(image: NSImage, size: CGSize) -> NSImage? {
        guard size.width > 0 && size.height > 0 else { return image }
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size),
                   from: .zero,
                   operation: .copy,
                   fraction: 1)
        result.unlockFocus()
        return result
    }

    private func storeInMemory(image: NSImage, for key: ImageCacheKey) {
        // Approximate byte size: width * height * 4 bytes/pixel
        let bytes = Int(key.size.width * key.size.height * 4)
        let entry = CachedImage(image: image, byteSize: bytes)
        memoryCache.setObject(entry, forKey: key.diskKey as NSString, cost: bytes)
    }

    private func diskPath(for key: ImageCacheKey) -> URL {
        diskCacheURL.appendingPathComponent("\(key.diskKey).png")
    }

    private func loadFromDisk(key: ImageCacheKey) -> NSImage? {
        let path = diskPath(for: key)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return NSImage(contentsOf: path)
    }

    private func saveToDisk(image: NSImage, key: ImageCacheKey) {
        let path = diskPath(for: key)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: path, options: .atomic)
    }
}
