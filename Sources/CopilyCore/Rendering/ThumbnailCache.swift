import CoreGraphics
import Foundation
import ImageIO

/// Cache key of a thumbnail: the asset and the size it was generated for.
public struct ThumbnailKey: Sendable, Hashable, Codable {
    public let assetID: AssetID
    public let maxPixelSize: Int

    public init(assetID: AssetID, maxPixelSize: Int) {
        self.assetID = assetID
        self.maxPixelSize = maxPixelSize
    }
}

/// A decoded thumbnail. `CGImage` is immutable and safe to share between threads,
/// which is what lets thumbnails be generated off the main actor and cached.
public struct ThumbnailImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelSize: CGSize

    public init(cgImage: CGImage, pixelSize: CGSize) {
        self.cgImage = cgImage
        self.pixelSize = pixelSize
    }

    /// Approximation of the decoded footprint, used to bound the cache.
    public var byteCost: Int {
        cgImage.bytesPerRow * cgImage.height
    }
}

public enum ThumbnailError: Error, Sendable, Equatable {
    case unreadableImage(String)
    case generationFailed(String)
}

/// Bounded least-recently-used thumbnail cache.
///
/// The byte limit is 32 MB by default, matching the rendering budget: scrolling
/// long image histories reuses thumbnails and evicts the coldest ones instead of
/// growing without limit.
public actor ThumbnailCache {
    public static let defaultByteLimit = 32 * 1024 * 1024

    public let byteLimit: Int

    private var storage: [ThumbnailKey: ThumbnailImage] = [:]
    private var order: [ThumbnailKey] = []
    private var inFlight: [ThumbnailKey: Task<ThumbnailImage, any Error>] = [:]
    private var cachedByteCount = 0

    public init(byteLimit: Int = ThumbnailCache.defaultByteLimit) {
        self.byteLimit = max(0, byteLimit)
    }

    public var byteCount: Int {
        cachedByteCount
    }

    public var count: Int {
        storage.count
    }

    public func contains(_ key: ThumbnailKey) -> Bool {
        storage[key] != nil
    }

    /// Returns a cached thumbnail, or generates one and caches it. Concurrent
    /// requests for the same key share a single generation.
    public func thumbnail(
        for key: ThumbnailKey,
        generate: @Sendable @escaping () async throws -> ThumbnailImage
    ) async throws -> ThumbnailImage {
        if let cached = storage[key] {
            touch(key)
            return cached
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await generate() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let image = try await task.value
        store(key, image)
        return image
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
        cachedByteCount = 0
    }

    public func remove(_ key: ThumbnailKey) {
        guard let removed = storage.removeValue(forKey: key) else { return }
        cachedByteCount -= removed.byteCost
        order.removeAll { $0 == key }
    }

    private func store(_ key: ThumbnailKey, _ image: ThumbnailImage) {
        if let existing = storage[key] {
            cachedByteCount -= existing.byteCost
            order.removeAll { $0 == key }
        }
        storage[key] = image
        order.append(key)
        cachedByteCount += image.byteCost
        evictIfNeeded()
    }

    private func touch(_ key: ThumbnailKey) {
        guard let index = order.firstIndex(of: key), index != order.count - 1 else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func evictIfNeeded() {
        while cachedByteCount > byteLimit, let oldest = order.first {
            order.removeFirst()
            if let removed = storage.removeValue(forKey: oldest) {
                cachedByteCount -= removed.byteCost
            }
        }
    }
}

/// Generates thumbnails from stored assets, off the main actor.
public enum ThumbnailRenderer {
    public static func thumbnail(for url: URL, maxPixelSize: Int) async throws -> ThumbnailImage {
        try await Task.detached(priority: .utility) {
            try render(url: url, maxPixelSize: maxPixelSize)
        }.value
    }

    static func render(url: URL, maxPixelSize: Int) throws -> ThumbnailImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ThumbnailError.unreadableImage(url.path)
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw ThumbnailError.unreadableImage(url.path)
        }
        let options: [CFString: any Sendable] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThumbnailError.generationFailed(url.path)
        }
        return ThumbnailImage(
            cgImage: image,
            pixelSize: CGSize(width: image.width, height: image.height)
        )
    }
}
