import Foundation

/// Reading the content a drop hands over.
///
/// A drop arrives as item providers, and each one has to be asked for its flavours one
/// by one. Which flavours Copily reads is decided here, so what a drop stores can be
/// checked without AppKit; the app target only turns a provider into the bytes.
public enum DropCaptureMapping {
    /// Pasteboard flavours a drop can carry, in the order they are read. PDFs are left
    /// alone, exactly as the capture loop leaves them.
    public static let supportedKinds: [ClipboardRepresentationKind] = ClipboardRepresentationKind.allCases
        .filter { $0 != .pdf }

    /// Which flavours of one dropped item to read, given the type identifiers it
    /// registers. Unknown types are ignored.
    public static func readableKinds(among registeredTypeIdentifiers: [String]) -> [ClipboardRepresentationKind] {
        let registered = Set(registeredTypeIdentifiers)
        return supportedKinds.filter { registered.contains($0.pasteboardType) }
    }
}
