import AppKit
import Foundation
import KopiCore

/// Bounded card previews. Each card observes its own entry, so loading a thumbnail
/// does not invalidate the entire grid. The renderer's cache alone cannot bound
/// memory while the UI also retains every image it has ever requested.
@MainActor
final class PreviewStore {
    enum Payload {
        case image(CGImage, pixelSize: CGSize)
        case richText(RichTextDocument)
        case code(CodeHighlight)

        var byteCost: Int {
            switch self {
            case .image(let image, _): image.bytesPerRow * image.height
            case .richText(let document): document.runs.reduce(0) { $0 + $1.text.utf8.count * 4 + 64 }
            case .code(let highlight): highlight.tokens.count * 64
            }
        }
    }

    final class Entry: ObservableObject {
        @Published fileprivate(set) var payload: Payload?
        fileprivate var pixelSizeLimit = 0
        fileprivate var fingerprint: ContentFingerprint?

        var image: CGImage? {
            if case .image(let image, _)? = payload { return image }
            return nil
        }

        var richText: RichTextDocument? {
            if case .richText(let document)? = payload { return document }
            return nil
        }

        var code: CodeHighlight? {
            if case .code(let highlight)? = payload { return highlight }
            return nil
        }
    }

    private struct Request {
        let token: UUID
        let fingerprint: ContentFingerprint
        let pixelSizeLimit: Int
    }

    private let store: HistoryStore
    private let processor: CaptureProcessor
    private let code: CodeHighlightService
    private let entryLimit: Int
    private let byteLimit: Int
    private var entries: [ClipboardItemID: Entry] = [:]
    private var order: [ClipboardItemID] = []
    private var inFlight: [ClipboardItemID: Request] = [:]

    init(
        store: HistoryStore,
        processor: CaptureProcessor,
        code: CodeHighlightService = CodeHighlightService(),
        entryLimit: Int = 120,
        byteLimit: Int = 32 * 1024 * 1024
    ) {
        self.store = store
        self.processor = processor
        self.code = code
        self.entryLimit = max(1, entryLimit)
        self.byteLimit = max(0, byteLimit)
    }

    var cachedEntryCount: Int { entries.count }
    var cachedByteCount: Int { entries.values.reduce(0) { $0 + ($1.payload?.byteCost ?? 0) } }

    func entry(for itemID: ClipboardItemID) -> Entry {
        if let entry = entries[itemID] {
            touch(itemID)
            return entry
        }
        let entry = Entry()
        entries[itemID] = entry
        touch(itemID)
        return entry
    }

    func invalidate(_ itemID: ClipboardItemID) {
        inFlight[itemID] = nil
        entries[itemID]?.fingerprint = nil
        entries[itemID]?.pixelSizeLimit = 0
        entries[itemID]?.payload = nil
    }

    func load(_ item: ClipboardItemSummary, maxPixelSize: Int = 320) async {
        let entry = entry(for: item.id)
        let requiredSize = item.kind == .image ? max(1, maxPixelSize) : 0
        guard entry.fingerprint != item.fingerprint || entry.pixelSizeLimit < requiredSize else { return }
        if let running = inFlight[item.id], running.fingerprint == item.fingerprint,
           running.pixelSizeLimit >= requiredSize { return }
        let token = UUID()
        inFlight[item.id] = Request(token: token, fingerprint: item.fingerprint, pixelSizeLimit: requiredSize)
        defer {
            if inFlight[item.id]?.token == token { inFlight[item.id] = nil }
            trim()
        }

        let payload: Payload?
        switch item.kind {
        case .image:
            payload = await imagePayload(for: item.id, maxPixelSize: maxPixelSize)
        case .richText:
            payload = await richTextPayload(for: item.id)
        case .text:
            payload = await code.highlight(text: item.excerpt, sourceApp: item.sourceApp).map(Payload.code)
        case .link, .files:
            payload = nil
        }
        guard !Task.isCancelled, inFlight[item.id]?.token == token,
              entries[item.id] === entry else { return }
        // A retry must remain possible if an image/record failed to load.
        guard payload != nil || item.kind == .text || item.kind == .link || item.kind == .files else { return }
        entry.payload = payload
        entry.fingerprint = item.fingerprint
        entry.pixelSizeLimit = requiredSize
        touch(item.id)
    }

    func largeImage(for item: ClipboardItemSummary, maxPixelSize: Int = 1600) async -> CGImage? {
        guard item.kind == .image,
              case .image(let image, _)? = await imagePayload(for: item.id, maxPixelSize: maxPixelSize)
        else { return nil }
        return image
    }

    func codeHighlight(for item: ClipboardItemSummary, text: String) async -> CodeHighlight? {
        await code.highlight(text: text, sourceApp: item.sourceApp)
    }

    func image(for itemID: ClipboardItemID) -> CGImage? { entries[itemID]?.image }
    func richText(for itemID: ClipboardItemID) -> RichTextDocument? { entries[itemID]?.richText }
    func code(for itemID: ClipboardItemID) -> CodeHighlight? { entries[itemID]?.code }

    private func touch(_ itemID: ClipboardItemID) {
        order.removeAll { $0 == itemID }
        order.append(itemID)
    }

    private func trim() {
        while entries.count > entryLimit || cachedByteCount > byteLimit {
            guard let oldest = order.first else { break }
            // A single oversized preview is not retained either.
            order.removeFirst()
            if let entry = entries.removeValue(forKey: oldest) {
                entry.payload = nil
                entry.fingerprint = nil
                entry.pixelSizeLimit = 0
            }
            inFlight[oldest] = nil
        }
    }

    private func imagePayload(for itemID: ClipboardItemID, maxPixelSize: Int) async -> Payload? {
        guard let detail = try? await store.detail(for: itemID),
              let reference = detail.representations.first(where: { $0.kind.isImage })?.asset,
              let thumbnail = try? await processor.thumbnail(for: reference, maxPixelSize: maxPixelSize)
        else { return nil }
        return .image(thumbnail.cgImage, pixelSize: thumbnail.pixelSize)
    }

    private func richTextPayload(for itemID: ClipboardItemID) async -> Payload? {
        guard let detail = try? await store.detail(for: itemID) else { return nil }
        if let data = detail.representation(.rtf)?.data, let document = RichTextCoding.document(fromRTF: data) {
            return .richText(document)
        }
        if let html = detail.representation(.html)?.text, let document = RichTextCoding.document(fromHTML: html) {
            return .richText(document)
        }
        return detail.plainText.map { .richText(RichTextDocument(plainText: $0)) }
    }
}
