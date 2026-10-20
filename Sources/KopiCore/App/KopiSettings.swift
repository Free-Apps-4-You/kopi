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
    /// Defaults suite written by earlier builds.
    ///
    /// This is an archived suite name: its values are read once, when the current
    /// suite has no settings yet, and never written again.
    public static let archivedSuiteName = "com.copily.Copily"
    public static let archivedSuiteNames = [archivedSuiteName, "com.velpy.Velpy"]
    public static let storageKey = "kopi.settings"
    /// Set once the archived suite has been considered, so Reset to Defaults is not
    /// undone by the next launch importing the old values again.
    static let migrationKey = "kopi.settings.migrationCompleted"

    @Published public private(set) var settings: KopiSettings

    private let defaults: UserDefaults

    /// - Parameters:
    ///   - defaults: Storage to use. Tests pass a temporary suite; the application
    ///     passes nothing and uses ``suiteName``.
    ///   - archivedDefaults: Earlier suite to copy settings from. The application
    ///     passes nothing and the archived suite is used; tests inject a temporary
    ///     one. A store built with an injected `defaults` never reads the real
    ///     archive unless it is passed explicitly.
    public init(defaults: UserDefaults? = nil, archivedDefaults: UserDefaults? = nil) {
        let resolved = defaults ?? UserDefaults(suiteName: KopiSettingsStore.suiteName) ?? .standard
        if let archivedDefaults {
            Self.copyArchivedSettingsIfNeeded(from: archivedDefaults, to: resolved)
        } else if defaults == nil {
            for suite in Self.archivedSuiteNames {
                if let archived = UserDefaults(suiteName: suite) {
                    Self.copyArchivedSettingsIfNeeded(from: archived, to: resolved)
                }
            }
        }
        self.defaults = resolved
        self.settings = Self.load(from: resolved)
    }

    /// Copies the settings blob an earlier build wrote, once.
    ///
    /// A value already stored in the current suite always wins, which makes a
    /// second launch — and a launch after the user changed a setting — a no-op.
    static func copyArchivedSettingsIfNeeded(from archived: UserDefaults, to current: UserDefaults) {
        guard current.data(forKey: storageKey) == nil,
              !current.bool(forKey: migrationKey)
        else { return }
        // A reset in the previous app must not reimport an even older preference.
        if archived.data(forKey: "copily.settings") == nil,
           archived.bool(forKey: "copily.settings.migrationCompleted") {
            current.set(try? JSONEncoder().encode(KopiSettings()), forKey: storageKey)
            current.set(true, forKey: migrationKey)
            return
        }
        guard let blob = archivedSettingsBlob(in: archived) else { return }
        current.set(blob, forKey: storageKey)
        current.set(true, forKey: migrationKey)
    }

    /// Finds the blob in the earlier suite's values.
    ///
    /// Earlier builds stored the blob under a preference name that carried the old
    /// application name, so the archive is recognised by its shape: a data value
    /// under a settings key that decodes as settings and is not just the defaults.
    /// Undecodable values, values that carry no choice, and the unrelated
    /// system-wide defaults a `UserDefaults` view also reports are ignored.
    private static func archivedSettingsBlob(in archived: UserDefaults) -> Data? {
        for key in [storageKey, "copily.settings", "velpy.settings"] {
            if let data = archived.data(forKey: key),
               (try? JSONDecoder().decode(KopiSettings.self, from: data)) != nil { return data }
        }
        let defaults = KopiSettings()
        for (key, value) in archived.dictionaryRepresentation() {
            guard key.hasSuffix(".settings") else { continue }
            guard let data = value as? Data,
                  let decoded = try? JSONDecoder().decode(KopiSettings.self, from: data),
                  decoded != defaults
            else { continue }
            return data
        }
        return nil
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
        // Keep the migration from restoring values the user just discarded.
        defaults.set(true, forKey: Self.migrationKey)
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
