import Foundation
import ServiceManagement

/// Launch at login, through `SMAppService`.
///
/// Registration only means something for a real application bundle, which the
/// command line build is not: it reports itself as unsupported instead of failing, and
/// the packaged build registers normally.
@MainActor
enum LaunchAtLogin {
    enum Status: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unsupported(String)

        var isOn: Bool { self == .enabled || self == .requiresApproval }

        var displayName: String {
            switch self {
            case .enabled: "On"
            case .disabled: "Off"
            case .requiresApproval: "Waiting for approval in System Settings"
            case .unsupported(let reason): reason
            }
        }
    }

    /// Whether this process runs from an application bundle.
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var status: Status {
        guard isSupported else {
            return .unsupported("Available in the packaged app")
        }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Registers or unregisters the login item, reporting a failure as a message
    /// instead of throwing into the settings UI.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Status {
        guard isSupported else {
            return .unsupported("Available in the packaged app")
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return .unsupported(error.localizedDescription)
        }
        return status
    }
}
