import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import CopilyCore

@Suite("Thumbnails")
struct ThumbnailCacheTests {
    @Test("The cache evicts the coldest thumbnails at its byte budget")
    func eviction() async throws {
        let cache = ThumbnailCache(byteLimit: 4 * 1024)
        for index in 0..<8 {
            let key = ThumbnailKey(assetID: AssetID(rawValue: "asset-\(index)"), maxPixelSize: 16)
            _ = try await cache.thumbnail(for: key) { makeTestImage(width: 16, height: 16) }
        }

        let bytes = await cache.byteCount
        let count = await cache.count
        #expect(bytes <= 4 * 1024)
        #expect(count < 8)
        #expect(count > 0)

        let newest = ThumbnailKey(assetID: AssetID(rawValue: "asset-7"), maxPixelSize: 16)
        let oldest = ThumbnailKey(assetID: AssetID(rawValue: "asset-0"), maxPixelSize: 16)
        let newestCached = await cache.contains(newest)
        let oldestCached = await cache.contains(oldest)
        #expect(newestCached)
        #expect(oldestCached == false)
    }

    @Test("Reading a cached thumbnail refreshes its recency")
    func recencyIsRefreshed() async throws {
        let cache = ThumbnailCache(byteLimit: 3 * 16 * 16 * 4)
        let keys = (0..<3).map { ThumbnailKey(assetID: AssetID(rawValue: "asset-\($0)"), maxPixelSize: 16) }
        for key in keys {
            _ = try await cache.thumbnail(for: key) { makeTestImage(width: 16, height: 16) }
        }

        // Touch the first key, then add one more so exactly one entry must go.
        _ = try await cache.thumbnail(for: keys[0]) { makeTestImage(width: 16, height: 16) }
        let overflow = ThumbnailKey(assetID: AssetID(rawValue: "asset-overflow"), maxPixelSize: 16)
        _ = try await cache.thumbnail(for: overflow) { makeTestImage(width: 16, height: 16) }

        let firstStillCached = await cache.contains(keys[0])
        let overflowCached = await cache.contains(overflow)
        #expect(firstStillCached)
        #expect(overflowCached)
    }

    @Test("Concurrent requests for one key generate a single thumbnail")
    func concurrentRequestsShareGeneration() async throws {
        let cache = ThumbnailCache()
        let counter = CallCounter()
        let key = ThumbnailKey(assetID: AssetID(rawValue: "shared"), maxPixelSize: 32)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try? await cache.thumbnail(for: key) {
                        try await Task.sleep(for: .milliseconds(30))
                        await counter.increment()
                        return makeTestImage(width: 32, height: 32)
                    }
                }
            }
        }

        let generations = await counter.value
        #expect(generations == 1)
        let cached = await cache.contains(key)
        #expect(cached)
    }

    @Test("A thumbnail of an image file respects the requested size")
    func renderingAnImageFile() async throws {
        let workspace = try TempWorkspace()
        let url = workspace.root.appendingPathComponent("large.png")
        try writeTestPNG(width: 128, height: 64, to: url)

        let thumbnail = try await ThumbnailRenderer.thumbnail(for: url, maxPixelSize: 32)
        #expect(max(thumbnail.pixelSize.width, thumbnail.pixelSize.height) <= 32)
        #expect(thumbnail.pixelSize.width > 0)
        #expect(thumbnail.cgImage.width > 0)
    }

    @Test("An unreadable file is reported instead of crashing")
    func unreadableFile() async throws {
        let workspace = try TempWorkspace()
        let url = workspace.root.appendingPathComponent("not-an-image.png")
        try Data("not really a png".utf8).write(to: url)

        var thrown: (any Error)?
        do {
            _ = try await ThumbnailRenderer.thumbnail(for: url, maxPixelSize: 32)
        } catch {
            thrown = error
        }
        #expect(thrown as? ThumbnailError == .unreadableImage(url.path))
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func makeTestImage(width: Int, height: Int) -> ThumbnailImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fatalError("could not create a test image")
    }
    return ThumbnailImage(cgImage: image, pixelSize: CGSize(width: width, height: height))
}

private func writeTestPNG(width: Int, height: Int, to url: URL) throws {
    let image = makeTestImage(width: width, height: height).cgImage
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw ThumbnailError.generationFailed(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ThumbnailError.generationFailed(url.path)
    }
}
