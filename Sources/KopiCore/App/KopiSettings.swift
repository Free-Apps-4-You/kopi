import Combine
import Foundation

/// Appearance setting of the Settings window.
public enum AppearancePreference: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Duration shared by the panel reveal and Settings window entrance.
public enum AnimationSpeed: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case fast, normal, relaxed
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
    public var openingDuration: TimeInterval {
        switch self { case .fast: 0.18; case .normal: 0.28; case .relaxed: 0.42 }
    }
    public var closingDuration: TimeInterval { openingDuration * 0.55 }
}

/// Hover-to-reveal behaviour inside the physical camera housing on supported displays.
public struct HoverReveal: Sendable, Hashable, Codable {
    /// Delays the UI offers, in seconds.
    public static let delayRange: ClosedRange<TimeInterval> = 0.1 ... 1.5
    public static let `default` = HoverReveal()

    public var isEnabled: Bool
    public var delay: TimeInterval

    public init(isEnabled: Bool = true, delay: TimeInterval = 0.35) {
        self.isEnabled = isEnabled
        self.delay = min(max(delay, HoverReveal.delayRange.lowerBound), HoverReveal.delayRange.upperBound)
    }

    /// How long the pointer has to rest in the trigger area.
    public var dwell: Duration { .seconds(delay) }
}

/// Everything the Settings window persists in `UserDefaults`.
///
/// History retention is deliberately absent: it belongs to ``HistoryStore``, which
/// applies it to stored cards, and is read back from the store instead of being
/// duplicated here.
public struct KopiSettings: Sendable, Hashable, Codable {
    public var radialCopiesOnly: Bool
    public var radialTrigger: RadialTrigger
    public var radialEnabled: Bool
    public var hotkey: HotkeyDefinition
    public var isHotkeyEnabled: Bool
    public var hoverReveal: HoverReveal
    /// Whether a click outside the panel dismisses it.
    public var dismissesOnOutsideClick: Bool
    public var launchAtLogin: Bool
    public var appearance: AppearancePreference
    public var animationSpeed: AnimationSpeed
    public var usesCompactCards: Bool
    public var isCapturePaused: Bool
    /// Opt in to importing content copied before the app was launched.
    public var capturesClipboardOnLaunch: Bool
    /// Bundle identifiers excluded from capture.
    public var excludedApplications: [String]
    /// Apple Notes folders included in the Notes tab.
    public var notesFolderIDs: [String]
    /// Distinguishes first-run defaults from deliberately excluding every folder.
    public var notesFoldersConfigured: Bool

    public init(
        radialEnabled: Bool = true,
        radialCopiesOnly: Bool = false,
        radialTrigger: RadialTrigger = .optionSpace,
        hotkey: HotkeyDefinition = .default,
        isHotkeyEnabled: Bool = true,
        hoverReveal: HoverReveal = .default,
        dismissesOnOutsideClick: Bool = true,
        launchAtLogin: Bool = false,
        appearance: AppearancePreference = .system,
        animationSpeed: AnimationSpeed = .normal,
        usesCompactCards: Bool = false,
        isCapturePaused: Bool = false,
        capturesClipboardOnLaunch: Bool = false,
        excludedApplications: [String] = [],
        notesFolderIDs: [String] = [],
        notesFoldersConfigured: Bool = false
    ) {
        self.radialCopiesOnly = radialCopiesOnly
        self.radialTrigger = radialTrigger
        self.radialEnabled = radialEnabled
        self.hotkey = hotkey
        self.isHotkeyEnabled = isHotkeyEnabled
        self.hoverReveal = hoverReveal
        self.dismissesOnOutsideClick = dismissesOnOutsideClick
        self.launchAtLogin = launchAtLogin
        self.appearance = appearance
        self.animationSpeed = animationSpeed
        self.usesCompactCards = usesCompactCards
        self.isCapturePaused = isCapturePaused
        self.capturesClipboardOnLaunch = capturesClipboardOnLaunch
        self.excludedApplications = excludedApplications
        self.notesFolderIDs = notesFolderIDs
        self.notesFoldersConfigured = notesFoldersConfigured || !notesFolderIDs.isEmpty
    }

    /// Decoded field by field so a stored value written by an earlier build keeps
    /// working after a new setting is added — or an old one is removed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = KopiSettings()
        radialCopiesOnly = try container.decodeIfPresent(Bool.self, forKey: .radialCopiesOnly) ?? false
        radialTrigger = try container.decodeIfPresent(RadialTrigger.self, forKey: .radialTrigger) ?? .optionSpace
        radialEnabled = try container.decodeIfPresent(Bool.self, forKey: .radialEnabled) ?? true
        hotkey = try container.decodeIfPresent(HotkeyDefinition.self, forKey: .hotkey) ?? defaults.hotkey
        isHotkeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .isHotkeyEnabled) ?? defaults.isHotkeyEnabled
        hoverReveal = try container.decodeIfPresent(HoverReveal.self, forKey: .hoverReveal) ?? defaults.hoverReveal
        dismissesOnOutsideClick = try container.decodeIfPresent(Bool.self, forKey: .dismissesOnOutsideClick) ?? defaults.dismissesOnOutsideClick
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? defaults.appearance
        animationSpeed = try container.decodeIfPresent(AnimationSpeed.self, forKey: .animationSpeed) ?? defaults.animationSpeed
        usesCompactCards = try container.decodeIfPresent(Bool.self, forKey: .usesCompactCards) ?? defaults.usesCompactCards
        isCapturePaused = try container.decodeIfPresent(Bool.self, forKey: .isCapturePaused) ?? defaults.isCapturePaused
        capturesClipboardOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .capturesClipboardOnLaunch) ?? false
        excludedApplications = try container.decodeIfPresent([String].self, forKey: .excludedApplications) ?? []
        notesFolderIDs = try container.decodeIfPresent([String].self, forKey: .notesFolderIDs) ?? []
        notesFoldersConfigured = try container.decodeIfPresent(Bool.self, forKey: .notesFoldersConfigured) ?? !notesFolderIDs.isEmpty
    }

    /// The shortcut to register, or `nil` when the user turned the hotkey off.
    public var activeHotkey: HotkeyDefinition? {
        isHotkeyEnabled && hotkey.isValid ? hotkey : nil
    }

    /// Applications excluded from capture, in the form ``ClipboardService`` takes.
    public var exclusion: ExcludedApplications {
        ExcludedApplications(bundleIdentifiers: Set(excludedApplications))
    }
}

/// `UserDefaults`-backed settings, observed by the Settings window and by the
/// controllers that act on them.
///
/// Writes are made on every change, so nothing else has to remember to save.
@MainActor
public final class KopiSettingsStore: ObservableObject {
    /// Defaults suite. An explicit suite is used rather than `.standard` because the
    /// command line build runs without an application bundle and therefore has no
    /// bundle identifier to key preferences by.
    public static let suiteName = "com.kopi.Kopi"
    public static let storageKey = "kopi.settings"

    @Published public private(set) var settings: KopiSettings

    private let defaults: UserDefaults

    /// Tests can inject an isolated preferences suite.
    public init(defaults: UserDefaults? = nil) {
        let resolved = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
        self.defaults = resolved
        self.settings = Self.load(from: resolved)
    }

    /// Applies a change and persists the result.
    public func update(_ change: (inout KopiSettings) -> Void) {
        var updated = settings
        change(&updated)
        replace(with: updated)
    }

    public func replace(with updated: KopiSettings) {
        guard updated != settings || defaults.data(forKey: Self.storageKey) == nil else { return }
        settings = updated
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        settings = KopiSettings()
    }

    private static func load(from defaults: UserDefaults) -> KopiSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(KopiSettings.self, from: data)
        else {
            return KopiSettings()
        }
        return decoded
    }
}
