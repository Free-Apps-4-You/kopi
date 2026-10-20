import Foundation

/// Evenly spaced clockwise directions starting at the top, with a safe center cancel zone.
public enum RadialSelection {
    public static func index(x: Double, y: Double, count: Int) -> Int? {
        guard count > 0, hypot(x, y) >= 48 else { return nil }
        let slots = min(count, 8)
        let step = 2 * Double.pi / Double(slots)
        let angle = atan2(x, y) + step / 2
        return (Int(floor(angle / step)) + slots) % slots
    }
}

public enum RadialTrigger: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, optionR
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .optionR: "⌥R"
        }
    }
    public var hotkey: HotkeyDefinition {
        switch self {
        case .optionSpace: HotkeyDefinition(keyCode: 49, modifiers: [.option], keyLabel: "Space")
        case .controlOptionSpace: HotkeyDefinition(keyCode: 49, modifiers: [.control, .option], keyLabel: "Space")
        case .optionR: HotkeyDefinition(keyCode: 15, modifiers: [.option], keyLabel: "R")
        }
    }
}
