import Foundation

/// One clockwise arc, with zero at twelve o'clock. All slices share boundaries,
/// including while focus moves between them.
public struct RadialSlice: Sendable, Equatable {
    public let index: Int
    public let count: Int
    public let startAngle: Double
    public let sweep: Double
    public var centerAngle: Double { startAngle + sweep / 2 }

    public func contains(angle: Double, tolerance: Double = 0) -> Bool {
        let difference = atan2(sin(angle - centerAngle), cos(angle - centerAngle))
        return abs(difference) <= sweep / 2 + tolerance
    }
}

/// A circular fisheye: growing one arc redistributes the remaining circumference
/// instead of scaling a wedge over its neighbors. Fractional emphasis lets the
/// UI interpolate the entire partition with one animation.
public struct RadialWheelLayout: Sendable {
    public let slices: [RadialSlice]

    public init(count: Int, focused: Int?) {
        var emphasis = Array(repeating: 0.0, count: max(0, min(8, count)))
        if let focused, emphasis.indices.contains(focused) { emphasis[focused] = 1 }
        self.init(count: count, emphasis: emphasis)
    }

    public init(count: Int, emphasis: [Double] = []) {
        let count = max(0, min(8, count))
        guard count > 0 else { slices = []; return }
        let step = 2 * Double.pi / Double(count)
        let weights = (0..<count).map { index in
            index < emphasis.count && emphasis[index].isFinite ? max(0, min(1, emphasis[index])) : 0
        }
        let total = weights.reduce(0, +)
        // Preserve the requested linear magnification as additional sector area.
        let extra = RadialGeometry.hoverScale * RadialGeometry.hoverScale - 1
        let widths = weights.map { weight in
            count == 1 ? step : step * (1 + extra * (weight - (total - weight) / Double(count - 1)))
        }
        var cursor = -step / 2
        var shift = 0.0
        for index in 0..<count {
            // Keep the focused direction anchored instead of rotating the wheel
            // away from the pointer. Blended focus remains continuous too.
            shift += weights[index] * (Double(index) * step - (cursor + widths[index] / 2))
            cursor += widths[index]
        }
        cursor = -step / 2 + shift
        slices = (0..<count).map { index in
            let slice = RadialSlice(index: index, count: count, startAngle: cursor, sweep: widths[index])
            cursor += widths[index]
            return slice
        }
    }
}
