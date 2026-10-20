import AppKit
import CoreServices
import Foundation

/// Whether Copily may send Apple Events to Apple Notes.
public enum NotesAutomationPermission: Sendable, Hashable {
    /// Automation is allowed.
    case authorized
    /// The user denied automation for Copily; only System Settings can change that.
    case denied
    /// Consent could not be determined, so the first real request decides.
    case undetermined
}

/// Asks macOS whether Copily may control Apple Notes.
public protocol NotesAutomationPermissionChecking: Sendable {
    func requestAutomationPermission() async -> NotesAutomationPermission
}

/// Preflights automation consent with `AEDeterminePermissionToAutomateTarget`, which
/// is the only way to raise the consent request without sending an event first.
///
/// Notes has to be running for the answer to be meaningful: macOS reports
/// `procNotFound` (-600) for a target that is not, which is indistinguishable from a
/// denial. Copily therefore opens Notes once and asks again, and maps both -1743
/// (`errAEEventNotPermitted`) and -600 to `.denied`.
public struct AppleEventPermissionChecker: NotesAutomationPermissionChecking {
    public typealias StatusProvider = @Sendable (_ askUserIfNeeded: Bool) -> OSStatus
    public typealias NotesLauncher = @Sendable () -> Void

    private let status: StatusProvider
    private let launchNotes: NotesLauncher
    private let retryDelay: Duration

    public init(
        bundleIdentifier: String = ScriptingBridgeNotesRunner.bundleIdentifier,
        retryDelay: Duration = .seconds(2),
        status: StatusProvider? = nil,
        launchNotes: NotesLauncher? = nil
    ) {
        self.retryDelay = retryDelay
        self.status = status ?? { askUserIfNeeded in
            Self.determinePermission(bundleIdentifier: bundleIdentifier, askUserIfNeeded: askUserIfNeeded)
        }
        self.launchNotes = launchNotes ?? { Self.launchNotes(bundleIdentifier: bundleIdentifier) }
    }

    public func requestAutomationPermission() async -> NotesAutomationPermission {
        var status = self.status(true)
        if Self.targetNeedsToBeRunning(status) {
            launchNotes()
            try? await Task.sleep(for: retryDelay)
            status = self.status(true)
        }
        return Self.permission(for: status)
    }

    /// -600 is the answer for a target that is not running and for one that is not
    /// installed at all, so it is reported as a denial once Notes has been offered a
    /// chance to start.
    static func targetNeedsToBeRunning(_ status: OSStatus) -> Bool {
        status == AppleEventStatus.targetNotFound
    }

    static func permission(for status: OSStatus) -> NotesAutomationPermission {
        switch status {
        case AppleEventStatus.success: .authorized
        case AppleEventStatus.eventNotPermitted,
             AppleEventStatus.targetNotFound,
             AppleEventStatus.wouldRequireConsent:
            .denied
        default:
            .undetermined
        }
    }

    /// The consent request itself: an address descriptor for Notes, wildcard events,
    /// and `askUserIfNeeded` so macOS can put the prompt up.
    static func determinePermission(bundleIdentifier: String, askUserIfNeeded: Bool) -> OSStatus {
        var address = AEAddressDesc()
        let created = bundleIdentifier.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &address)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&address) }
        return AEDeterminePermissionToAutomateTarget(
            &address,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }

    /// Opens Notes without bringing it forward, only when it is not already running.
    static func launchNotes(bundleIdentifier: String) {
        Task { @MainActor in
            let workspace = NSWorkspace.shared
            guard !workspace.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            workspace.openApplication(at: url, configuration: configuration) { _, _ in }
        }
    }
}
