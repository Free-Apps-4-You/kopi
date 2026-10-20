import AppKit
import KopiCore

extension AppearancePreference {
    /// AppKit appearance the setting stands for, or `nil` to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
