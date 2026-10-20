import AppKit
import Foundation
import KopiCore

/// File icons for file cards and previews.
///
/// Icons come from the workspace for files that are still where they were copied from,
/// and from a system symbol once the original has moved away — including for a pinned
/// card that only exists as Kopi's own copy.
@MainActor
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()
    static let pointSize = CGSize(width: 16, height: 16)

    static func icon(for reference: FileReference) -> NSImage {
        let key = (reference.isOriginalAvailable ? reference.path : "symbol:\(reference.displayName)") as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image: NSImage
        if reference.isOriginalAvailable {
            image = NSWorkspace.shared.icon(forFile: reference.path)
        } else {
            image = NSImage(systemSymbolName: symbolName(for: reference), accessibilityDescription: reference.displayName)
                ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                ?? NSImage()
        }
        image.size = pointSize
        cache.setObject(image, forKey: key)
        return image
    }

    private static func symbolName(for reference: FileReference) -> String {
        symbolName(forFileName: reference.displayName, isDirectory: reference.isDirectory)
    }

    /// Symbol for a file name, used where only the name of a copied file is at hand.
    static func symbolName(forFileName name: String, isDirectory: Bool = false) -> String {
        if isDirectory { return "folder" }
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar": return "doc.zipper"
        case "mov", "mp4": return "film"
        case "mp3", "m4a", "wav": return "waveform"
        case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "h", "cpp": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}
