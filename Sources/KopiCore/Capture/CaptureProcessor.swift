import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Failures of content preparation.
public enum CaptureProcessorError: Error, Sendable, Equatable, LocalizedError {
    /// The pasteboard held nothing Kopi understands.
    case unsupportedContent
    case imageDataUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedContent: "This clipboard content is not supported."
        case .imageDataUnavailable: "This image is a private app file. Copy the image itself to capture a preview."
        }
    }
}

/// Converts one pasteboard snapshot into a storable capture.
///
/// The processor owns content preparation: flavour extraction, plain text for rich
/// copies, importing image bytes into Kopi's asset store, and thumbnail access. It
/// holds no pasteboard and no database, so every decision it makes can be checked on
/// plain snapshots.
public actor CaptureProcessor {
    /// Pixel size thumbnails are generated for on clipboard cards.
    public static let defaultThumbnailPixelSize = 256

    private let assetStore: AssetStore
    private let thumbnailCache: ThumbnailCache

    public init(assetStore: AssetStore, thumbnailCache: ThumbnailCache = ThumbnailCache()) {
        self.assetStore = assetStore
        self.thumbnailCache = thumbnailCache
    }

    // MARK: - Thumbnails

    /// Thumbnail of an image asset, generated off the main actor and kept in the
    /// shared bounded cache, so scrolling a long image history does not re-render.
    public func thumbnail(for asset: AssetReference, maxPixelSize: Int? = nil) async throws -> ThumbnailImage {
        let pixelSize = maxPixelSize ?? Self.defaultThumbnailPixelSize
        let key = ThumbnailKey(assetID: asset.id, maxPixelSize: pixelSize)
        let url = assetStore.fileURL(for: asset)
        return try await thumbnailCache.thumbnail(for: key) {
            try await ThumbnailRenderer.thumbnail(for: url, maxPixelSize: pixelSize)
        }
    }

    // MARK: - Kind

    /// A single decodable image file is an image, including clipboard screenshot
    /// URLs. Mixed file selections stay together as files. Otherwise file references
    /// take priority over alternate flavours, followed by image bytes, links and text.
    public nonisolated static func kind(of snapshot: PasteboardSnapshot) -> ClipboardItemKind? {
        if !fileURLs(in: snapshot).isEmpty { return imageFileURL(in: snapshot) == nil ? .files : .image }
        if imageFlavour(in: snapshot) != nil { return .image }
        if urlString(in: snapshot) != nil { return .link }
        if hasRichFlavour(in: snapshot) { return .richText }
        if plainText(in: snapshot) != nil { return .text }
        return nil
    }

    // MARK: - Capture

    /// Prepares the card for a snapshot: representations, file references and, for
    /// images, an asset holding the original bytes.
    public func insertion(
        from snapshot: PasteboardSnapshot,
        sourceApp: SourceAppInfo? = nil,
        origin: CopyOrigin,
        capturedAt: Date = Date(),
        destination: CaptureDestination = .history
    ) async throws -> ClipboardItemInsertion {
        guard let kind = Self.kind(of: snapshot) else {
            throw CaptureProcessorError.unsupportedContent
        }
        switch kind {
        case .files:
            return ClipboardItemInsertion(
                kind: .files,
                representations: [],
                fileReferences: Self.fileReferences(in: snapshot),
                sourceApp: sourceApp,
                origin: origin,
                capturedAt: capturedAt,
                destination: destination
            )
        case .image:
            return try await imageInsertion(
                from: snapshot,
                sourceApp: sourceApp,
                origin: origin,
                capturedAt: capturedAt,
                destination: destination
            )
        case .link:
            return linkInsertion(
                from: snapshot,
                sourceApp: sourceApp,
                origin: origin,
                capturedAt: capturedAt,
                destination: destination
            )
        case .richText:
            return richTextInsertion(
                from: snapshot,
                sourceApp: sourceApp,
                origin: origin,
                capturedAt: capturedAt,
                destination: destination
            )
        case .text:
            let text = Self.plainText(in: snapshot) ?? ""
            return ClipboardItemInsertion(
                kind: .text,
                text: text,
                representations: [ClipboardRepresentation(kind: .plainText, payload: .text(text))],
                sourceApp: sourceApp,
                origin: origin,
                capturedAt: capturedAt,
                destination: destination
            )
        }
    }

    // MARK: - Snapshots

    private func imageInsertion(
        from snapshot: PasteboardSnapshot,
        sourceApp: SourceAppInfo?,
        origin: CopyOrigin,
        capturedAt: Date,
        destination: CaptureDestination
    ) async throws -> ClipboardItemInsertion {
        let flavour: ClipboardRepresentationKind
        let data: Data
        if let image = Self.imageFlavour(in: snapshot), let bytes = snapshot.data(for: image.pasteboardType) {
            flavour = image
            data = bytes
        } else if let url = Self.imageFileURL(in: snapshot) {
            guard !Self.isPrivateAppStorage(url) else { throw CaptureProcessorError.imageDataUnavailable }
            let bytes = try Data(contentsOf: url)
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?
            else { throw CaptureProcessorError.unsupportedContent }
            if let original = ClipboardRepresentationKind.allCases.first(where: { $0.isImage && $0.pasteboardType == type }) {
                flavour = original
                data = bytes
            } else {
                // Formats without a clipboard flavour (e.g. BMP) become real PNG
                // data, never a file URL masquerading as an image.
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureProcessorError.unsupportedContent }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
                else { throw CaptureProcessorError.unsupportedContent }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CaptureProcessorError.unsupportedContent }
                flavour = .png
                data = output as Data
            }
        } else { throw CaptureProcessorError.unsupportedContent }
        let stored = try await assetStore.importData(
            data,
            kind: .image,
            fileExtension: flavour.fileExtension,
            createdAt: capturedAt
        )
        return ClipboardItemInsertion(
            kind: .image,
            representations: [ClipboardRepresentation(kind: flavour, payload: .asset(stored.reference))],
            sourceApp: sourceApp,
            origin: origin,
            capturedAt: capturedAt,
            destination: destination
        )
    }

    private func linkInsertion(
        from snapshot: PasteboardSnapshot,
        sourceApp: SourceAppInfo?,
        origin: CopyOrigin,
        capturedAt: Date,
        destination: CaptureDestination
    ) -> ClipboardItemInsertion {
        let urlString = Self.urlString(in: snapshot) ?? ""
        let text = Self.plainText(in: snapshot) ?? urlString
        return ClipboardItemInsertion(
            kind: .link,
            text: text,
            url: URL(string: urlString),
            representations: [
                ClipboardRepresentation(kind: .plainText, payload: .text(text)),
                ClipboardRepresentation(kind: .link, payload: .text(urlString))
            ],
            sourceApp: sourceApp,
            origin: origin,
            capturedAt: capturedAt,
            destination: destination
        )
    }

    private func richTextInsertion(
        from snapshot: PasteboardSnapshot,
        sourceApp: SourceAppInfo?,
        origin: CopyOrigin,
        capturedAt: Date,
        destination: CaptureDestination
    ) -> ClipboardItemInsertion {
        let html = snapshot.string(for: ClipboardRepresentationKind.html.pasteboardType)
        let rtf = snapshot.data(for: ClipboardRepresentationKind.rtf.pasteboardType)
        let plainText = Self.plainText(in: snapshot)
            ?? html.map(PlainTextExtraction.plainText(fromHTML:))
            ?? rtf.map(PlainTextExtraction.plainText(fromRTF:))
            ?? ""

        var representations = [ClipboardRepresentation(kind: .plainText, payload: .text(plainText))]
        if let html {
            representations.append(ClipboardRepresentation(kind: .html, payload: .text(html)))
        }
        if let rtf {
            representations.append(ClipboardRepresentation(kind: .rtf, payload: .data(rtf)))
        }
        return ClipboardItemInsertion(
            kind: .richText,
            text: plainText,
            representations: representations,
            sourceApp: sourceApp,
            origin: origin,
            capturedAt: capturedAt,
            destination: destination
        )
    }

    // MARK: - Flavour reading

    /// File URLs of a Finder copy, deduplicated by path and in pasteboard order.
    static func fileURLs(in snapshot: PasteboardSnapshot) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for value in snapshot.strings(for: ClipboardRepresentationKind.fileURL.pasteboardType) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed), url.isFileURL else { continue }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    /// No protected app directories are probed during classification. Image bytes
    /// supplied by the clipboard can still be used without opening the file URL.
    static func imageFileURL(in snapshot: PasteboardSnapshot) -> URL? {
        let urls = fileURLs(in: snapshot)
        guard urls.count == 1, let url = urls.first,
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        else { return nil }
        if isPrivateAppStorage(url) || imageFlavour(in: snapshot) != nil { return url }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetType(source) != nil
        else { return nil }
        return url
    }

    /// Clipboard file URLs do not authorize reading another application's data.
    /// Check the lexical path before any stat, ImageIO or data read can trigger TCC.
    static func isPrivateAppStorage(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let ownAssets = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kopi/Assets").path
        if path.hasPrefix(ownAssets + "/") { return false }
        return path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
            || path.contains("/Library/Application Support/")
    }

    /// File cards keep references only; Kopi copies the content when the card is pinned.
    static func fileReferences(in snapshot: PasteboardSnapshot) -> [FileReference] {
        fileURLs(in: snapshot).map { url in
            let path = url.standardizedFileURL.path
            let values: URLResourceValues? = isPrivateAppStorage(url) ? nil : try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            return FileReference(
                path: path,
                displayName: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                byteSize: isDirectory ? nil : values?.fileSize.map { Int64($0) },
                isDirectory: isDirectory
            )
        }
    }

    /// First image flavour present, in the fidelity order of the kind cases.
    static func imageFlavour(in snapshot: PasteboardSnapshot) -> ClipboardRepresentationKind? {
        ClipboardRepresentationKind.allCases.first { kind in
            kind.isImage && snapshot.items.contains { $0.hasData(for: kind.pasteboardType) }
        }
    }

    static func urlString(in snapshot: PasteboardSnapshot) -> String? {
        let type = ClipboardRepresentationKind.link.pasteboardType
        guard let value = snapshot.string(for: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func plainText(in snapshot: PasteboardSnapshot) -> String? {
        let type = ClipboardRepresentationKind.plainText.pasteboardType
        guard let text = snapshot.string(for: type), !text.isEmpty else { return nil }
        return text
    }

    static func hasRichFlavour(in snapshot: PasteboardSnapshot) -> Bool {
        snapshot.data(for: ClipboardRepresentationKind.html.pasteboardType) != nil
            || snapshot.data(for: ClipboardRepresentationKind.rtf.pasteboardType) != nil
    }
}
