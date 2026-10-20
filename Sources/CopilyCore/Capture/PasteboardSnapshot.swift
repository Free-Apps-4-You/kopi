import Foundation

/// One pasteboard flavour: a type identifier and the bytes it carries.
public struct PasteboardFlavour: Sendable, Hashable, Identifiable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }

    /// Flavour whose bytes are the UTF-8 encoding of `string`.
    public init(type: String, string: String) {
        self.init(type: type, data: Data(string.utf8))
    }

    public var id: String { type }

    /// The bytes decoded as UTF-8, when the flavour is text at all.
    public var string: String? {
        String(data: data, encoding: .utf8)
    }
}

/// One pasteboard item: the alternate representations of a single copied thing.
public struct PasteboardItemSnapshot: Sendable, Hashable {
    public let flavours: [PasteboardFlavour]

    public init(flavours: [PasteboardFlavour]) {
        self.flavours = flavours
    }

    public var isEmpty: Bool { flavours.isEmpty }

    public func flavours(ofType type: String) -> [PasteboardFlavour] {
        flavours.filter { $0.type == type }
    }

    public func data(for type: String) -> Data? {
        flavours.first { $0.type == type && !$0.data.isEmpty }?.data
    }

    public func string(for type: String) -> String? {
        flavours.first { $0.type == type && !$0.data.isEmpty }?.string
    }

    public func hasData(for type: String) -> Bool {
        flavours.contains { $0.type == type && !$0.data.isEmpty }
    }
}

/// Immutable, AppKit-free snapshot of a pasteboard read.
///
/// `changeCount` is the pasteboard generation observed when the read started.
/// Comparing it with the live counter afterwards is what lets the capture loop
/// reject a snapshot the clipboard changed underneath.
public struct PasteboardSnapshot: Sendable, Hashable {
    public let changeCount: Int
    public let items: [PasteboardItemSnapshot]

    public init(changeCount: Int, items: [PasteboardItemSnapshot]) {
        self.changeCount = changeCount
        self.items = items
    }

    public var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    public func data(for type: String) -> Data? {
        items.lazy.compactMap { $0.data(for: type) }.first
    }

    public func string(for type: String) -> String? {
        items.lazy.compactMap { $0.string(for: type) }.first
    }

    /// One decoded value per item that carries `type`, in pasteboard order.
    public func strings(for type: String) -> [String] {
        items.compactMap { $0.string(for: type) }
    }
}

/// Content Copily places on the pasteboard: one item per copied thing, in order.
public struct PasteboardWriteRequest: Sendable, Hashable {
    public let items: [PasteboardItemSnapshot]

    public init(items: [PasteboardItemSnapshot]) {
        self.items = items
    }

    /// Request for a single pasteboard item.
    public init(flavours: [PasteboardFlavour]) {
        self.init(items: [PasteboardItemSnapshot(flavours: flavours)])
    }

    public var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    public var flavours: [PasteboardFlavour] {
        items.flatMap(\.flavours)
    }
}

/// Pasteboard access used by the capture pipeline.
///
/// Clipboard observation never talks to `NSPasteboard` directly: ``NSPasteboardAccess``
/// adapts it, tests supply their own implementation, and the service only sees
/// immutable snapshots.
public protocol PasteboardAccessing: Sendable {
    /// Monotonic generation counter. The clipboard has new content whenever it moves.
    var changeCount: Int { get }

    /// Reads the flavours Copily understands. The result records the generation that
    /// was current when the read started.
    func readSnapshot() throws -> PasteboardSnapshot

    /// Replaces the pasteboard contents with `request` and returns the new generation.
    @discardableResult
    func write(_ request: PasteboardWriteRequest) throws -> Int
}

/// Failure modes of pasteboard access.
public enum PasteboardAccessError: Error, Sendable, Equatable {
    /// The system reports that Copily may not read the pasteboard. Repeating the read
    /// is pointless until the user allows access again.
    case accessDenied
    case readFailed(String)
    case writeFailed(String)
}
