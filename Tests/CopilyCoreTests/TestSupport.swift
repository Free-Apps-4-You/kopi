import Foundation
import Testing

@testable import CopilyCore

/// Temporary working directory holding a database and an asset store. Removed when
/// the test that created it ends.
final class TempWorkspace: @unchecked Sendable {
    let root: URL
    let assetStore: AssetStore
    let store: HistoryStore

    private let copier: any AssetFileCopying

    init(copier: any AssetFileCopying = FileManagerAssetCopier()) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copily-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.copier = copier
        let assetStore = try AssetStore(
            rootDirectory: root.appendingPathComponent("Assets", isDirectory: true),
            copier: copier
        )
        self.assetStore = assetStore
        self.store = try HistoryStore(path: root.appendingPathComponent("history.sqlite").path, assetStore: assetStore)
    }

    var databasePath: String {
        root.appendingPathComponent("history.sqlite").path
    }

    /// Second store over the same database file, as a relaunch would open it.
    func reopenStore() throws -> HistoryStore {
        try HistoryStore(path: databasePath, assetStore: assetStore)
    }

    func writeFile(_ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Copier that records what it copied, and can fail or stall on demand.
actor RecordingAssetCopier: AssetFileCopying {
    private(set) var copiedSources: [String] = []
    private let delay: Duration
    private let failure: (any Error)?

    init(delay: Duration = .zero, failure: (any Error)? = nil) {
        self.delay = delay
        self.failure = failure
    }

    func copyItem(at source: URL, to destination: URL) async throws {
        if let failure {
            throw failure
        }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        copiedSources.append(source.path)
    }
}

// MARK: - Builders

func textInsertion(
    _ text: String,
    label: String? = nil,
    capturedAt: Date = Date(),
    origin: CopyOrigin = .external(changeCount: 0),
    destination: CaptureDestination = .history,
    id: ClipboardItemID = ClipboardItemID()
) -> ClipboardItemInsertion {
    ClipboardItemInsertion(
        id: id,
        kind: .text,
        label: label,
        text: text,
        representations: [ClipboardRepresentation(kind: .plainText, payload: .text(text))],
        origin: origin,
        capturedAt: capturedAt,
        destination: destination
    )
}

func richTextInsertion(
    _ text: String,
    label: String? = nil,
    capturedAt: Date = Date(),
    origin: CopyOrigin = .external(changeCount: 0),
    destination: CaptureDestination = .history
) -> ClipboardItemInsertion {
    let document = RichTextDocument(runs: [RichTextDocument.Run(text: text, traits: .bold)])
    return ClipboardItemInsertion(
        kind: .richText,
        label: label,
        text: text,
        representations: [
            ClipboardRepresentation(kind: .plainText, payload: .text(text)),
            ClipboardRepresentation(kind: .html, payload: .text(document.html())),
            ClipboardRepresentation(kind: .rtf, payload: .data(document.rtf()))
        ],
        origin: origin,
        capturedAt: capturedAt,
        destination: destination
    )
}

func linkInsertion(
    _ urlString: String,
    label: String? = nil,
    capturedAt: Date = Date(),
    origin: CopyOrigin = .external(changeCount: 0),
    destination: CaptureDestination = .history
) -> ClipboardItemInsertion {
    let url = URL(string: urlString)
    let display = label ?? urlString
    return ClipboardItemInsertion(
        kind: .link,
        label: label,
        text: display,
        url: url,
        representations: [
            ClipboardRepresentation(kind: .plainText, payload: .text(display)),
            ClipboardRepresentation(kind: .link, payload: .text(urlString))
        ],
        origin: origin,
        capturedAt: capturedAt,
        destination: destination
    )
}

func fileInsertion(
    _ urls: [URL],
    label: String? = nil,
    capturedAt: Date = Date(),
    origin: CopyOrigin = .external(changeCount: 0),
    destination: CaptureDestination = .history
) -> ClipboardItemInsertion {
    let references = urls.map { url in
        FileReference(
            path: url.path,
            displayName: url.lastPathComponent,
            byteSize: fileSize(of: url)
        )
    }
    return ClipboardItemInsertion(
        kind: .files,
        label: label,
        representations: [],
        fileReferences: references,
        origin: origin,
        capturedAt: capturedAt,
        destination: destination
    )
}

func fileSize(of url: URL) -> Int64? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value
}

func imageInsertion(
    asset: AssetReference,
    label: String? = nil,
    capturedAt: Date = Date(),
    origin: CopyOrigin = .external(changeCount: 0),
    destination: CaptureDestination = .history
) -> ClipboardItemInsertion {
    ClipboardItemInsertion(
        kind: .image,
        label: label,
        representations: [ClipboardRepresentation(kind: .png, payload: .asset(asset))],
        origin: origin,
        capturedAt: capturedAt,
        destination: destination
    )
}

extension HistoryPageResult {
    var itemIDs: [ClipboardItemID] {
        items.map(\.id)
    }
}

extension Date {
    static func daysAgo(_ days: Double) -> Date {
        Date().addingTimeInterval(-days * 24 * 60 * 60)
    }
}
