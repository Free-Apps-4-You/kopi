import Foundation

/// Evenly spaced clockwise directions starting at the top, with a safe center cancel zone.
public enum RadialGeometry {
    public static let outerRadius = 220.0
    public static let cancelRadius = 48.0
    public static let hoverScale = 1.05
    public static let singleItemHoverScale = hoverScale
    // Keep the full outward zoom and its controls inside the transparent window.
    public static let windowWidth = 600.0
    public static let windowHeight = 672.0
    public static let wheelCenterX = 300.0
    public static let wheelCenterY = 300.0
    public static let dockCenterY = 564.0

    /// Move only the controls when a lower focused wedge needs their space.
    public static func dockY(focused: Int?, count: Int, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion, let focused, (0..<count).contains(focused) else { return dockCenterY }
        let sweep = 2 * Double.pi / Double(count)
        let start = Double(focused) * sweep - sweep / 2
        let end = start + sweep
        let bottomDirection = (.pi - start).truncatingRemainder(dividingBy: 2 * .pi)
        let containsBottom = (bottomDirection < 0 ? bottomDirection + 2 * .pi : bottomDirection) <= sweep
        let bottom = max(-cos(start) * outerRadius, -cos(end) * outerRadius,
                         -cos(start) * cancelRadius, -cos(end) * cancelRadius,
                         containsBottom ? outerRadius : -outerRadius)
        let scale = count == 1 ? singleItemHoverScale : hoverScale
        return max(dockCenterY, wheelCenterY + bottom * scale + 48)
    }
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
