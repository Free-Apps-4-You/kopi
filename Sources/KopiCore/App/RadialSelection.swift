import Foundation

/// Evenly spaced clockwise directions starting at the top, with a safe center cancel zone.
public enum RadialGeometry {
    public static let outerRadius = 220.0
    public static let cancelRadius = 48.0
    public static let hoverScale = 1.272
}

public enum RadialSelection {
    public static func index(x: Double, y: Double, count: Int, previous: Int? = nil) -> Int? {
        guard count > 0, hypot(x, y) >= RadialGeometry.cancelRadius else { return nil }
        let slots = min(count, 8)
        let step = 2 * Double.pi / Double(slots)
        let direction = atan2(x, y)
        if let previous, previous >= 0, previous < slots {
            let difference = atan2(sin(direction - Double(previous) * step), cos(direction - Double(previous) * step))
            if abs(difference) < step / 2 + .pi / 36 { return previous }
        }
        let angle = direction + step / 2
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
