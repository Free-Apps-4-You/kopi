import AppKit
import CoreText
import KopiCore

/// Horizontal content follows the wedge instead of inheriting a square card's
/// padding. The inset also leaves a quiet lane for each keyboard number.
struct RadialContentLayout {
    let index: Int
    let count: Int
    private let radius = RadialGeometry.outerRadius
    private let padding = 10.0
    private let direction: CGPoint
    private let sinHalf: Double
    private let cosHalf: Double

    init(index: Int, count: Int) {
        self.index = index
        self.count = max(1, min(8, count))
        let angle = Double(index) * 2 * .pi / Double(self.count) - .pi / 2
        direction = CGPoint(x: cos(angle), y: sin(angle))
        sinHalf = sin(.pi / Double(self.count))
        cosHalf = cos(.pi / Double(self.count))
    }

    func contains(_ rect: CGRect) -> Bool {
        let closestX = max(rect.minX - radius, min(0, rect.maxX - radius))
        let closestY = max(rect.minY - radius, min(0, rect.maxY - radius))
        guard hypot(closestX, closestY) >= 83 else { return false }
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            let x = point.x - radius, y = point.y - radius
            let distance = hypot(x, y)
            guard distance <= radius - padding else { return false }
            if count > 1 {
                let along = x * direction.x + y * direction.y
                let across = -x * direction.y + y * direction.x
                guard along * sinHalf - abs(across) * cosHalf >= padding else { return false }
            }
        }
        return true
    }

    /// Maximal complete preview along the sector's bisector. Aspect ratios are
    /// preserved; screenshots never become enlarged, unrecognizable crops.
    func imageRect(aspectRatio: Double) -> CGRect {
        let aspect = max(0.05, min(20, aspectRatio))
        var best = CGRect.zero
        for distance in stride(from: 90.0, through: radius - padding, by: 2) {
            let center = CGPoint(x: radius + direction.x * distance, y: radius + direction.y * distance)
            var low = 0.0, high = radius * 2
            for _ in 0..<13 {
                let width = (low + high) / 2
                let rect = CGRect(x: center.x - width / 2, y: center.y - width / aspect / 2,
                                  width: width, height: width / aspect)
                if contains(rect) { low = width } else { high = width }
            }
            let rect = CGRect(x: center.x - low / 2, y: center.y - low / aspect / 2,
                              width: low, height: low / aspect)
            if rect.width * rect.height > best.width * best.height { best = rect }
        }
        return best
    }

    func textRows(lineHeight: Double = 18) -> [CGRect] {
        // Sparse wheels have broad sectors; one comfortable column is easier to
        // scan than text flowing around both sides of the hub.
        if count <= 3 {
            let rect = imageRect(aspectRatio: 1.35)
            return stride(from: rect.minY, through: rect.maxY - lineHeight, by: lineHeight).map {
                CGRect(x: rect.minX, y: $0, width: rect.width, height: lineHeight)
            }
        }
        var rows: [CGRect] = []
        for y in stride(from: padding, through: radius * 2 - padding - lineHeight, by: lineHeight) {
            var start: Double?, end = 0.0
            var widest = CGRect.zero
            for x in stride(from: padding, through: radius * 2 - padding, by: 2) {
                if contains(CGRect(x: x, y: y, width: 2, height: lineHeight)) {
                    if start == nil { start = x }
                    end = x + 2
                } else if let beginning = start {
                    if end - beginning > widest.width { widest = CGRect(x: beginning, y: y, width: end - beginning, height: lineHeight) }
                    start = nil
                }
            }
            if let beginning = start, end - beginning > widest.width {
                widest = CGRect(x: beginning, y: y, width: end - beginning, height: lineHeight)
            }
            if widest.width >= 48 { rows.append(widest) }
        }
        return rows
    }
}

/// Core Text breaks lines against each available span, including long URLs and
/// unbroken strings. The final line gets an ellipsis rather than a clipped edge.
struct RadialTextFlow {
    struct Line {
        let text: CTLine
        let rect: CGRect
        var width: CGFloat {
            CGFloat(CTLineGetTypographicBounds(text, nil, nil, nil)) - CTLineGetTrailingWhitespaceWidth(text)
        }
    }

    static func lines(_ text: String, layout: RadialContentLayout, color: NSColor) -> [Line] {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
        ]
        let string = NSAttributedString(string: normalized, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let rows = layout.textRows()
        guard !rows.isEmpty, string.length > 0 else { return [] }
        var best: [Line] = []
        var bestConsumed = -1
        var bestCentering = Double.greatestFiniteMagnitude
        let middle = (rows[0].midY + rows[rows.count - 1].midY) / 2
        for start in rows.indices {
            var offset = 0
            var result: [Line] = []
            for row in rows[start...] {
                guard offset < string.length else { break }
                let length = CTTypesetterSuggestLineBreak(typesetter, offset, row.width)
                guard length > 0 else { break }
                var line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length))
                if row == rows.last, offset + length < string.length {
                    let remainder = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: string.length - offset))
                    let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                    line = CTLineCreateTruncatedLine(remainder, row.width, .end, ellipsis) ?? line
                }
                result.append(Line(text: line, rect: row))
                offset += length
            }
            let centering = result.isEmpty ? .infinity : abs((result[0].rect.midY + result[result.count - 1].rect.midY) / 2 - middle)
            if offset > bestConsumed || (offset == bestConsumed && centering < bestCentering) {
                best = result; bestConsumed = offset; bestCentering = centering
            }
        }
        return best
    }
}
