import Foundation

/// Failures of the capture service itself.
public enum ClipboardServiceError: Error, Sendable, Equatable {
    /// The card has no content Kopi can place on the pasteboard.
    case nothingToWrite(ClipboardItemID)
    /// The clipboard kept changing while it was being read, so nothing was stored.
    case clipboardChanged
}

/// Observes the pasteboard, prepares captures and stores them.
///
/// The service is the serialized worker the design calls for: pasteboard reads,
/// content preparation and database writes all happen on this actor, and only the
/// published ``ClipboardCaptureStatus`` is main-actor. Reading is driven by
/// `changeCount`, so content is read only after the counter moves; polling runs every
/// ``defaultPollInterval`` while capture is running.
///
/// Clipboard contents are never logged. An outcome describes what happened to a
/// change, not what the change contained.
public actor ClipboardService {
    /// Poll interval of the design: checking a counter four times a second is cheap,
    /// and a copied item is visible well inside the 750 ms budget.
    public static let defaultPollInterval = Duration.milliseconds(250)

    private let store: HistoryStore
    private let pasteboard: any PasteboardAccessing
    private let processor: CaptureProcessor
    private let ticker: any CaptureTicking
    private let lifecycle: any PasteboardLifecycleObserving
    private let frontmostApp: any FrontmostAppProviding
    private let status: ClipboardCaptureStatus?
    private let pollInterval: Duration
    private var excludedApplications: ExcludedApplications

    private var isStarted = false
    private var isCaptureDisabled = false
    private var isSuspended = false
    private var block: ClipboardCaptureBlock?
    private var rememberedChangeCount: Int?
    private var launchImportChangeCount: Int?
    private var tickHandle: (any CaptureTickHandle)?
    private var lifecycleObservation: (any PasteboardLifecycleObservation)?

    /// Where the loop is. Mirrored to ``ClipboardCaptureStatus`` when one is supplied.
    public private(set) var state: ClipboardCaptureState = .idle
    /// Incremented every time ``state`` changes.
    public private(set) var revision = 0
    /// The most recent tick's outcome.
    public private(set) var lastOutcome: ClipboardCaptureOutcome?

    /// The pasteboard generation already accounted for, or `nil` before the first start.
    public var lastObservedChangeCount: Int? { rememberedChangeCount }

    public init(
        store: HistoryStore,
        pasteboard: any PasteboardAccessing,
        processor: CaptureProcessor,
        lifecycle: any PasteboardLifecycleObserving,
        frontmostApp: any FrontmostAppProviding,
        ticker: any CaptureTicking = TaskCaptureTicker(),
        status: ClipboardCaptureStatus? = nil,
        excludedApplications: ExcludedApplications = ExcludedApplications(),
        pollInterval: Duration = ClipboardService.defaultPollInterval
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.processor = processor
        self.lifecycle = lifecycle
        self.frontmostApp = frontmostApp
        self.ticker = ticker
        self.status = status
        self.excludedApplications = excludedApplications
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    /// Starts observing.
    ///
    /// The current clipboard generation becomes the starting point, so whatever was
    /// already on the pasteboard is skipped, unless the user explicitly opted in.
    public func start(captureExistingClipboard: Bool = false) async {
        guard !isStarted else { return }
        isStarted = true
        // A generation recorded by an earlier run can match a counter that restarted
        // with the login session, which would let an external copy through unnoticed.
        // Everything already on the pasteboard is covered by the starting generation.
        try? await store.clearOwnCopy()
        let initialChangeCount = pasteboard.changeCount
        launchImportChangeCount = captureExistingClipboard ? initialChangeCount : nil
        rememberedChangeCount = captureExistingClipboard ? nil : initialChangeCount
        lifecycleObservation = await lifecycle.observe { [weak self] event in
            await self?.handle(event)
        }
        await scheduleTicker()
        await publish()
    }

    /// Stops observing and cancels the scheduled tick.
    public func stop() async {
        guard isStarted else { return }
        isStarted = false
        lifecycleObservation?.cancel()
        lifecycleObservation = nil
        cancelTicker()
        await publish()
    }

    /// Turns capture off or on, from the Pause capture setting.
    ///
    /// Nothing is read or stored while capture is off, and the clipboard's latest
    /// content is captured once it is switched back on.
    public func setCapturePaused(_ isPaused: Bool) async {
        guard isCaptureDisabled != isPaused else { return }
        isCaptureDisabled = isPaused
        if isPaused {
            cancelTicker()
        } else {
            await scheduleTicker()
        }
        await publish()
    }

    public var isCapturePaused: Bool { isCaptureDisabled }

    /// Replaces the applications Kopi must not capture from.
    public func setExcludedApplications(_ excluded: ExcludedApplications) {
        excludedApplications = excluded
    }

    /// Clears a denied-access block — after the user allowed Kopi in System Settings —
    /// and resumes reading.
    public func clearAccessBlock() async {
        guard block != nil else { return }
        block = nil
        await scheduleTicker()
        await publish()
    }

    /// System sleep and wake. Observation stops before the Mac sleeps and resumes
    /// after it wakes.
    public func handle(_ event: PasteboardLifecycleEvent) async {
        switch event {
        case .willSleep:
            guard !isSuspended else { return }
            isSuspended = true
            cancelTicker()
        case .didWake:
            guard isSuspended else { return }
            isSuspended = false
            await scheduleTicker()
        }
        await publish()
    }

    // MARK: - Polling

    /// One polling tick.
    ///
    /// The loop calls this every ``pollInterval``; tests call it directly, so capture
    /// behaviour is checked without a clock.
    @discardableResult
    public func tick(now: Date = Date()) async -> ClipboardCaptureOutcome {
        let outcome = await performTick(now: now)
        lastOutcome = outcome
        await publish()
        if case .captured(_, let result) = outcome {
            await publishCapture(result.summary, at: now)
        }
        return outcome
    }

    private func performTick(now: Date) async -> ClipboardCaptureOutcome {
        guard isStarted else { return .idle }
        if let block { return .blocked(block) }
        if isSuspended { return .paused(.systemSleep) }
        if isCaptureDisabled { return .paused(.captureDisabled) }

        let changeCount = pasteboard.changeCount
        guard changeCount != rememberedChangeCount else { return .unchanged(changeCount: changeCount) }

        if let ownCopy = try? await store.ownCopyState(), ownCopy.changeCount == changeCount {
            rememberedChangeCount = changeCount
            return .ownCopy(itemID: ownCopy.itemID, changeCount: changeCount)
        }

        // A pre-launch copy has no trustworthy source. Never attribute it to the
        // app that happens to be frontmost when Kopi starts.
        let sourceApp = launchImportChangeCount == changeCount ? nil : frontmostApp.frontmostApp()
        guard !excludedApplications.excludes(sourceApp) else {
            rememberedChangeCount = changeCount
            return .excludedApp(changeCount: changeCount)
        }

        let snapshot: PasteboardSnapshot
        do {
            snapshot = try pasteboard.readSnapshot()
        } catch PasteboardAccessError.accessDenied {
            return await blockAccess()
        } catch {
            return .failed(changeCount: changeCount, reason: Self.describe(error))
        }

        let insertion: ClipboardItemInsertion
        do {
            insertion = try await processor.insertion(
                from: snapshot,
                sourceApp: sourceApp,
                origin: .external(changeCount: snapshot.changeCount),
                capturedAt: now
            )
        } catch CaptureProcessorError.unsupportedContent {
            rememberedChangeCount = snapshot.changeCount
            return .unsupported(changeCount: snapshot.changeCount)
        } catch {
            rememberedChangeCount = snapshot.changeCount
            return .failed(changeCount: snapshot.changeCount, reason: Self.describe(error))
        }

        let settled = pasteboard.changeCount
        guard settled == snapshot.changeCount else {
            // The clipboard moved while the snapshot was being prepared, so what was
            // extracted no longer describes it. Remember the read generation only, and
            // let the next tick pick up the newer content.
            rememberedChangeCount = snapshot.changeCount
            return .rejectedSnapshot(changeCount: settled)
        }

        do {
            let result = try await store.insert(insertion)
            rememberedChangeCount = settled
            return .captured(insertion, result)
        } catch {
            rememberedChangeCount = settled
            return .failed(changeCount: settled, reason: Self.describe(error))
        }
    }

    private func blockAccess() async -> ClipboardCaptureOutcome {
        block = .pasteboardAccessDenied
        cancelTicker()
        await publish()
        return .blocked(.pasteboardAccessDenied)
    }

    private func scheduleTicker() async {
        guard isStarted, !isSuspended, !isCaptureDisabled, block == nil, tickHandle == nil else { return }
        tickHandle = await ticker.schedule(every: pollInterval) { [weak self] in
            await self?.tick()
        }
    }

    private func cancelTicker() {
        tickHandle?.cancel()
        tickHandle = nil
    }

    private func publish() async {
        let resolved = resolvedState()
        guard resolved != state else { return }
        state = resolved
        revision += 1
        if let status {
            await status.apply(resolved, revision: revision)
        }
    }

    private func publishCapture(_ summary: ClipboardItemSummary, at timestamp: Date) async {
        guard let status else { return }
        await status.applyCapture(ClipboardCaptureSignal(summary: summary, timestamp: timestamp))
    }

    private func resolvedState() -> ClipboardCaptureState {
        guard isStarted else { return .idle }
        if let block { return .blocked(block) }
        if isSuspended { return .paused(.systemSleep) }
        if isCaptureDisabled { return .paused(.captureDisabled) }
        return .running
    }

    // MARK: - Copying a stored card

    /// Puts a stored card on the pasteboard as Kopi's own copy.
    ///
    /// The generation produced by the write is recorded, so the loop recognises it as
    /// ``ClipboardCaptureOutcome/ownCopy(itemID:changeCount:)`` instead of storing the
    /// card twice, while the next external copy still carries a different generation
    /// and is captured as usual.
    @discardableResult
    public func copyToPasteboard(_ itemID: ClipboardItemID) async throws -> OwnCopyState {
        let request = try await writeRequest(for: itemID)
        let changeCount = try pasteboard.write(request)
        let state = OwnCopyState(itemID: itemID, changeCount: changeCount)
        try await store.recordOwnCopy(state)
        return state
    }

    /// Puts plain text on the pasteboard as Kopi's own copy.
    ///
    /// Used for text that does not come from a stored card, such as copying a note
    /// body. The generation is recorded so the capture loop does not turn Kopi's own
    /// write into a card, while the next external copy still is captured.
    @discardableResult
    public func copyPlainTextToPasteboard(_ text: String) async throws -> OwnCopyState {
        let changeCount = try pasteboard.write(
            PasteboardWriteRequest(flavours: [
                PasteboardFlavour(type: ClipboardRepresentationKind.plainText.pasteboardType, string: text)
            ])
        )
        let state = OwnCopyState(itemID: ClipboardItemID(), changeCount: changeCount)
        try await store.recordOwnCopy(state)
        return state
    }

    /// The flavours a card is placed on the pasteboard as, without writing them.
    public func writeRequest(for itemID: ClipboardItemID) async throws -> PasteboardWriteRequest {
        guard let detail = try await store.detail(for: itemID) else {
            throw HistoryStoreError.itemNotFound(itemID)
        }
        switch detail.summary.kind {
        case .files:
            let items = detail.fileReferences.map { reference in
                PasteboardItemSnapshot(flavours: [
                    PasteboardFlavour(
                        type: ClipboardRepresentationKind.fileURL.pasteboardType,
                        string: reference.url.absoluteString
                    )
                ])
            }
            guard !items.isEmpty else { throw ClipboardServiceError.nothingToWrite(itemID) }
            return PasteboardWriteRequest(items: items)
        case .text, .richText, .link, .image:
            var flavours: [PasteboardFlavour] = []
            for representation in detail.representations {
                guard let data = try await payload(of: representation) else { continue }
                flavours.append(PasteboardFlavour(type: representation.kind.pasteboardType, data: data))
            }
            guard !flavours.isEmpty else { throw ClipboardServiceError.nothingToWrite(itemID) }
            return PasteboardWriteRequest(flavours: flavours)
        }
    }

    private func payload(of representation: ClipboardRepresentation) async throws -> Data? {
        switch representation.payload {
        case .text(let value):
            return Data(value.utf8)
        case .data(let bytes):
            return bytes
        case .asset(let reference):
            return try await store.assetStore.readData(for: reference)
        }
    }

    // MARK: - Adding content the user handed over

    /// Adds the current clipboard to a destination, because the user asked for it — the
    /// ⌘V of the collection view.
    ///
    /// This is the capture pipeline on demand rather than on a tick: the same
    /// ``PasteboardAccessing`` read and the same ``CaptureProcessor`` produce the card
    /// that a copy would have produced. The observation bookkeeping is deliberately left
    /// alone — the remembered generation and Kopi's own copy stay exactly as they were —
    /// so the loop still accounts for the change on its own terms. The clipboard is read
    /// again when it moves while the snapshot is being prepared, and the read is refused
    /// rather than retried when the system denies pasteboard access.
    @discardableResult
    public func captureClipboard(
        into destination: CaptureDestination,
        now: Date = Date()
    ) async throws -> HistoryInsertionResult {
        for _ in 0..<3 {
            let snapshot = try await readSnapshotForUser()
            let insertion = try await processor.insertion(
                from: snapshot,
                sourceApp: nil,
                origin: .external(changeCount: snapshot.changeCount),
                capturedAt: now,
                destination: destination
            )
            guard pasteboard.changeCount == snapshot.changeCount else { continue }
            return try await store.insert(insertion)
        }
        throw ClipboardServiceError.clipboardChanged
    }

    /// Adds a prepared snapshot to a destination: what a drop of content hands over.
    @discardableResult
    public func capture(
        _ snapshot: PasteboardSnapshot,
        into destination: CaptureDestination,
        label: String? = nil,
        now: Date = Date()
    ) async throws -> HistoryInsertionResult {
        var insertion = try await processor.insertion(
            from: snapshot,
            sourceApp: nil,
            origin: .external(changeCount: snapshot.changeCount),
            capturedAt: now,
            destination: destination
        )
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        insertion.label = trimmedLabel?.isEmpty == false ? trimmedLabel : nil
        return try await store.insert(insertion)
    }

    /// Reads a user-requested draft without storing it or changing capture bookkeeping.
    public func readSnapshotForUser() async throws -> PasteboardSnapshot {
        do {
            return try pasteboard.readSnapshot()
        } catch PasteboardAccessError.accessDenied {
            _ = await blockAccess()
            throw PasteboardAccessError.accessDenied
        }
    }

    // MARK: - Diagnostics

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as PasteboardAccessError:
            switch error {
            case .accessDenied: return "pasteboard access is denied"
            case .readFailed(let message): return "the pasteboard could not be read: \(message)"
            case .writeFailed(let message): return "the pasteboard could not be written: \(message)"
            }
        case let error as CaptureProcessorError:
            switch error {
            case .unsupportedContent: return "the clipboard holds nothing Kopi can store"
            case .imageDataUnavailable: return "This image is a private app file. Copy the image itself to capture a preview."
            }
        case let error as ClipboardServiceError:
            switch error {
            case .nothingToWrite: return "the card has no content to write"
            case .clipboardChanged: return "the clipboard changed while it was being read"
            }
        default:
            return error.localizedDescription
        }
    }
}
