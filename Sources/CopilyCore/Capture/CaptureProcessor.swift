import Foundation

/// Failures of content preparation.
public enum CaptureProcessorError: Error, Sendable, Equatable {
    /// The pasteboard held nothing Copily understands.
    case unsupportedContent
}

/// Converts one pasteboard snapshot into a storable capture.
///
/// The processor owns content preparation: flavour extraction, plain text for rich
/// copies, importing image bytes into Copily's asset store, and thumbnail access. It
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

    /// The kind a snapshot is captured as, in one place and in priority order:
    ///
    /// 1. file URLs → ``ClipboardItemKind/files``, a Finder copy however many files
    ///    it holds. A copy that carries files keeps pointing at them, so the files win
    ///    over every other flavour it may also expose.
    /// 2. image bytes, first of png, tiff, jpeg, heic, gif, webp → ``ClipboardItemKind/image``.
    /// 3. `public.url` → ``ClipboardItemKind/link``, whether or not the copy also
    ///    carries text or markup.
    /// 4. html or rtf → ``ClipboardItemKind/richText``.
    /// 5. plain text → ``ClipboardItemKind/text``.
    ///
    /// `nil` means the snapshot holds nothing Copily can store, for instance a PDF or a
    /// private flavour.
    public nonisolated static func kind(of snapshot: PasteboardSnapshot) -> ClipboardItemKind? {
        if !fileURLs(in: snapshot).isEmpty { return .files }
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
        guard let flavour = Self.imageFlavour(in: snapshot),
              let data = snapshot.data(for: flavour.pasteboardType)
        else {
            throw CaptureProcessorError.unsupportedContent
        }
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

    /// File cards keep references only; Copily copies the content when the card is pinned.
    static func fileReferences(in snapshot: PasteboardSnapshot) -> [FileReference] {
        fileURLs(in: snapshot).map { url in
            let path = url.standardizedFileURL.path
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
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
