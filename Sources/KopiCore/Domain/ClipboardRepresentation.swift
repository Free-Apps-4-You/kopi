import Foundation

/// The pasteboard flavours Kopi understands. Kept as plain strings so the core
/// never has to import AppKit.
public enum ClipboardRepresentationKind: String, Sendable, Codable, CaseIterable, Hashable {
    case plainText
    case html
    case rtf
    case link
    case fileURL
    case pdf
    case png
    case tiff
    case jpeg
    case heic
    case gif
    case webP

    public var isTextual: Bool {
        switch self {
        case .plainText, .html, .rtf, .link, .fileURL: true
        case .pdf, .png, .tiff, .jpeg, .heic, .gif, .webP: false
        }
    }

    public var isImage: Bool {
        switch self {
        case .png, .tiff, .jpeg, .heic, .gif, .webP: true
        case .plainText, .html, .rtf, .link, .fileURL, .pdf: false
        }
    }

    public var pasteboardType: String {
        switch self {
        case .plainText: "public.utf8-plain-text"
        case .html: "public.html"
        case .rtf: "public.rtf"
        case .link: "public.url"
        case .fileURL: "public.file-url"
        case .pdf: "com.adobe.pdf"
        case .png: "public.png"
        case .tiff: "public.tiff"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .gif: "com.compuserve.gif"
        case .webP: "org.webmproject.webp"
        }
    }

    public var fileExtension: String? {
        switch self {
        case .plainText: "txt"
        case .html: "html"
        case .rtf: "rtf"
        case .link, .fileURL: nil
        case .pdf: "pdf"
        case .png: "png"
        case .tiff: "tiff"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .gif: "gif"
        case .webP: "webp"
        }
    }
}

/// Where the bytes of a representation live.
public enum ClipboardRepresentationPayload: Sendable, Hashable, Codable {
    /// Small textual flavour stored inline in the database.
    case text(String)
    /// Binary flavour stored inline in the database.
    case data(Data)
    /// Large or reusable flavour stored in Kopi's asset directory.
    case asset(AssetReference)
}

/// One stored flavour of a clipboard item, for example its plain text and its RTF.
public struct ClipboardRepresentation: Sendable, Hashable, Codable, Identifiable {
    public let kind: ClipboardRepresentationKind
    public let payload: ClipboardRepresentationPayload
    public let byteCount: Int
    public let contentHash: String

    /// Computes the byte count and content hash of the payload.
    public init(kind: ClipboardRepresentationKind, payload: ClipboardRepresentationPayload) {
        self.kind = kind
        self.payload = payload
        switch payload {
        case .text(let value):
            byteCount = value.utf8.count
            contentHash = ContentHasher.sha256Hex(text: value)
        case .data(let bytes):
            byteCount = bytes.count
            contentHash = ContentHasher.sha256Hex(bytes)
        case .asset(let reference):
            byteCount = reference.byteCount
            contentHash = reference.contentHash
        }
    }

    /// Rebuilds a representation from stored values without re-hashing the payload.
    public init(
        kind: ClipboardRepresentationKind,
        payload: ClipboardRepresentationPayload,
        byteCount: Int,
        contentHash: String
    ) {
        self.kind = kind
        self.payload = payload
        self.byteCount = byteCount
        self.contentHash = contentHash
    }

    public var id: String { "\(kind.rawValue):\(contentHash)" }

    public var text: String? {
        if case .text(let value) = payload { return value }
        return nil
    }

    public var data: Data? {
        if case .data(let bytes) = payload { return bytes }
        return nil
    }

    public var asset: AssetReference? {
        if case .asset(let reference) = payload { return reference }
        return nil
    }

    public var isStoredInline: Bool {
        switch payload {
        case .text, .data: true
        case .asset: false
        }
    }
}
