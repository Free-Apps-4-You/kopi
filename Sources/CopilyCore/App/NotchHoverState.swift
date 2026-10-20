import Foundation
import CoreGraphics

/// Monotonic dwell tracking shared by mouse events and the deadline timer.
public struct NotchHoverState {
    private var target: CGRect?
    private var enteredAt: TimeInterval?
    private var suppressed = false
    public init() {}

    public static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        !rect.isEmpty && point.x >= rect.minX && point.x < rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }

    public mutating func reset() { self = Self() }

    public mutating func suppress(at point: CGPoint, targets: [CGRect]) {
        reset()
        target = targets.first { Self.contains(point, in: $0) }
        suppressed = target != nil
    }

    /// Returns a deadline while dwelling. Movement inside the same housing preserves entry time.
    public mutating func update(point: CGPoint, targets: [CGRect], now: TimeInterval, delay: TimeInterval) -> TimeInterval? {
        guard let next = targets.first(where: { Self.contains(point, in: $0) }) else {
            reset()
            return nil
        }
        if target != next {
            reset()
            target = next
        }
        guard !suppressed else { return nil }
        if enteredAt == nil { enteredAt = now }
        return enteredAt! + max(0, delay)
    }
}
