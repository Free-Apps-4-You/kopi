import CoreGraphics
import Foundation
import ImageIO

@testable import CopilyCore

// MARK: - Fake pasteboard

/// Scriptable pasteboard.
///
/// Nothing here touches the real `NSPasteboard`: capture tests never read or write the
/// clipboard of the machine they run on.
final class FakePasteboard: PasteboardAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var storedItems: [PasteboardItemSnapshot] = []
    private var reads = 0
    private var written: [PasteboardWriteRequest] = []
    private var nextError: (any Error)?
    private var persistentError: (any Error)?
    private var mutationDuringRead: [PasteboardItemSnapshot]?
    private var mutationOnEveryRead: [PasteboardItemSnapshot]?

    // MARK: PasteboardAccessing

    var changeCount: Int { lock.withLock { generation } }

    func readSnapshot() throws -> PasteboardSnapshot {
        try lock.withLock {
            reads += 1
            if let error = nextError {
                nextError = nil
                throw error
            }
            if let error = persistentError {
                throw error
            }
            let snapshot = PasteboardSnapshot(changeCount: generation, items: storedItems)
            if let mutation = mutationDuringRead ?? mutationOnEveryRead {
                mutationDuringRead = nil
                generation += 1
                storedItems = mutation
            }
            return snapshot
        }
    }

    @discardableResult
    func write(_ request: PasteboardWriteRequest) -> Int {
        lock.withLock {
            written.append(request)
            generation += 1
            storedItems = request.items
            return generation
        }
    }

    // MARK: Scripting

    var snapshotReadCount: Int { lock.withLock { reads } }

    var writeRequests: [PasteboardWriteRequest] { lock.withLock { written } }

    var items: [PasteboardItemSnapshot] { lock.withLock { storedItems } }

    /// Puts `items` on the pasteboard, the way an external copy does.
    func copy(_ items: [PasteboardItemSnapshot]) {
        lock.withLock {
            generation += 1
            storedItems = items
        }
    }

    func copyText(_ text: String) {
        copy([textItem(text)])
    }

    /// Fails the next read, as a refused read does.
    func failNextRead(with error: any Error) {
        lock.withLock { nextError = error }
    }

    /// Fails every read until ``allowReads()``, as denied pasteboard access does.
    func failReads(with error: any Error) {
        lock.withLock { persistentError = error }
    }

    func allowReads() {
        lock.withLock {
            persistentError = nil
            nextError = nil
        }
    }

    /// Makes the next read hand back the current content while the clipboard changes
    /// underneath it: a copy landing in the middle of extraction.
    func changeDuringNextRead(to items: [PasteboardItemSnapshot]) {
        lock.withLock { mutationDuringRead = items }
    }

    /// Makes every read hand back the current content while the clipboard changes
    /// underneath it, so a read can never settle on one generation.
    func changeDuringEveryRead(to items: [PasteboardItemSnapshot]) {
        lock.withLock { mutationOnEveryRead = items }
    }

    /// Stops the clipboard from moving during reads again.
    func settleReads() {
        lock.withLock { mutationOnEveryRead = nil }
    }
}

// MARK: - Capture loop doubles

/// Ticker that fires only when a test says so, and records what the service asked for.
final class ManualCaptureTicker: CaptureTicking, @unchecked Sendable {
    private let lock = NSLock()
    private var tick: (@Sendable () async -> Void)?
    private var intervals: [Duration] = []
    private var cancelled = true

    func schedule(
        every interval: Duration,
        tick: @Sendable @escaping () async -> Void
    ) async -> any CaptureTickHandle {
        lock.withLock {
            self.tick = tick
            self.intervals.append(interval)
            self.cancelled = false
        }
        return ManualTickHandle { [weak self] in
            self?.lock.withLock {
                self?.cancelled = true
                self?.tick = nil
            }
        }
    }

    /// Runs one tick if the service still has one scheduled; `false` when it does not.
    @discardableResult
    func fire() async -> Bool {
        let tick = lock.withLock { cancelled ? nil : tick }
        guard let tick else { return false }
        await tick()
        return true
    }

    var scheduleCount: Int { lock.withLock { intervals.count } }

    var scheduledIntervals: [Duration] { lock.withLock { intervals } }

    /// Whether the service currently has a live tick schedule.
    var isActive: Bool { lock.withLock { !cancelled && tick != nil } }
}

struct ManualTickHandle: CaptureTickHandle {
    let onCancel: @Sendable () -> Void

    func cancel() {
        onCancel()
    }
}

/// Lifecycle source whose events a test delivers, and waits for the service to act on.
final class ManualLifecycleObserver: PasteboardLifecycleObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (PasteboardLifecycleEvent) async -> Void)?
    private var observing = false

    func observe(
        _ handler: @Sendable @escaping (PasteboardLifecycleEvent) async -> Void
    ) async -> any PasteboardLifecycleObservation {
        lock.withLock {
            self.handler = handler
            self.observing = true
        }
        return ManualLifecycleObservation { [weak self] in
            self?.lock.withLock {
                self?.handler = nil
                self?.observing = false
            }
        }
    }

    /// Delivers an event and waits until the service has handled it.
    func emit(_ event: PasteboardLifecycleEvent) async {
        let handler = lock.withLock { handler }
        await handler?(event)
    }

    var isObserving: Bool { lock.withLock { observing } }
}

struct ManualLifecycleObservation: PasteboardLifecycleObservation {
    let onCancel: @Sendable () -> Void

    func cancel() {
        onCancel()
    }
}

/// Frontmost application a test decides on.
final class StubFrontmostApp: FrontmostAppProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var app: SourceAppInfo?
    private var lookups = 0

    var current: SourceAppInfo? {
        get { lock.withLock { app } }
        set { lock.withLock { app = newValue } }
    }

    var lookupCount: Int { lock.withLock { lookups } }

    func frontmostApp() -> SourceAppInfo? {
        lock.withLock {
            lookups += 1
            return app
        }
    }
}

// MARK: - Harness

/// Capture pipeline wired to fakes, over a throwaway store.
struct CaptureHarness {
    let workspace: TempWorkspace
    let processor: CaptureProcessor
    let thumbnailCache: ThumbnailCache
    let pasteboard: FakePasteboard
    let ticker: ManualCaptureTicker
    let lifecycle: ManualLifecycleObserver
    let frontmostApp: StubFrontmostApp
    let status: ClipboardCaptureStatus
    let service: ClipboardService

    init(
        excludedApplications: ExcludedApplications = ExcludedApplications(),
        pollInterval: Duration = ClipboardService.defaultPollInterval,
        thumbnailCache: ThumbnailCache = ThumbnailCache()
    ) async throws {
        let workspace = try TempWorkspace()
        let pasteboard = FakePasteboard()
        let ticker = ManualCaptureTicker()
        let lifecycle = ManualLifecycleObserver()
        let frontmostApp = StubFrontmostApp()
        let status = ClipboardCaptureStatus()
        let processor = CaptureProcessor(assetStore: workspace.assetStore, thumbnailCache: thumbnailCache)
        self.workspace = workspace
        self.processor = processor
        self.thumbnailCache = thumbnailCache
        self.pasteboard = pasteboard
        self.ticker = ticker
        self.lifecycle = lifecycle
        self.frontmostApp = frontmostApp
        self.status = status
        self.service = ClipboardService(
            store: workspace.store,
            pasteboard: pasteboard,
            processor: processor,
            lifecycle: lifecycle,
            frontmostApp: frontmostApp,
            ticker: ticker,
            status: status,
            excludedApplications: excludedApplications,
            pollInterval: pollInterval
        )
    }
}

// MARK: - Snapshot builders

func textItem(_ text: String) -> PasteboardItemSnapshot {
    PasteboardItemSnapshot(flavours: [flavour(.plainText, text)])
}

func richItem(plainText: String? = nil, html: String? = nil, rtf: Data? = nil) -> PasteboardItemSnapshot {
    var flavours: [PasteboardFlavour] = []
    if let plainText {
        flavours.append(flavour(.plainText, plainText))
    }
    if let html {
        flavours.append(flavour(.html, html))
    }
    if let rtf {
        flavours.append(PasteboardFlavour(type: ClipboardRepresentationKind.rtf.pasteboardType, data: rtf))
    }
    return PasteboardItemSnapshot(flavours: flavours)
}

func linkItem(_ url: String, text: String? = nil) -> PasteboardItemSnapshot {
    var flavours = [flavour(.link, url)]
    if let text {
        flavours.append(flavour(.plainText, text))
    }
    return PasteboardItemSnapshot(flavours: flavours)
}

func imageItem(_ data: Data, kind: ClipboardRepresentationKind = .png) -> PasteboardItemSnapshot {
    PasteboardItemSnapshot(flavours: [PasteboardFlavour(type: kind.pasteboardType, data: data)])
}

func fileItem(_ url: URL) -> PasteboardItemSnapshot {
    PasteboardItemSnapshot(flavours: [flavour(.fileURL, url.absoluteString)])
}

func flavour(_ kind: ClipboardRepresentationKind, _ string: String) -> PasteboardFlavour {
    PasteboardFlavour(type: kind.pasteboardType, data: Data(string.utf8))
}

func textSnapshot(_ text: String, changeCount: Int = 1) -> PasteboardSnapshot {
    PasteboardSnapshot(changeCount: changeCount, items: [textItem(text)])
}

// MARK: - Fixtures

/// A real PNG, so the asset store and the thumbnail renderer see decodable bytes.
func pngData(width: Int = 8, height: Int = 8) -> Data {
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
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
        fatalError("could not create an image destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not encode a test image")
    }
    return data as Data
}

/// RTF written by Copily's own encoder, so extraction is checked against the writer.
func rtfData(_ text: String, bold: Bool = false) -> Data {
    if bold {
        return RichTextDocument(runs: [RichTextDocument.Run(text: text, traits: .bold)]).rtf()
    }
    return RichTextDocument(plainText: text).rtf()
}

/// Counts ticks from the production ticker.
actor TickCounter {
    private(set) var value = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func increment() {
        value += 1
        waiter?.resume()
        waiter = nil
    }

    func waitForTick() async {
        guard value == 0 else { return }
        await withCheckedContinuation { continuation in
            if value == 0 {
                waiter = continuation
            } else {
                continuation.resume()
            }
        }
    }
}
