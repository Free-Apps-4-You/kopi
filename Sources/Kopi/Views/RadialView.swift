import SwiftUI
import CoreText
import KopiCore

/// Adjoining annular segments form one wheel around the compact cancel hub.
struct RadialView: View {
    @ObservedObject var state: RadialState
    let previews: PreviewStore
    let choose: (Int) -> Void
    let page: (Int) -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var entrance = PanelState(false)

    private var shown: Bool { entrance.value && state.presented }
    private var action: String { state.copiesOnly ? "copy" : "paste" }
    private let wheelSize = RadialGeometry.outerRadius * 2

    var body: some View {
        ZStack {
            Circle().fill(KopiTheme.surface.opacity(reduceTransparency ? 1 : 0.12))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 9)
                .frame(width: wheelSize, height: wheelSize).position(x: 300, y: 300)
                .allowsHitTesting(false)
            RadialWheel(state: state, previews: previews, choose: choose,
                        emphasis: RadialEmphasis(selected: !reduceMotion && !state.loading ? state.selected : nil))
                .position(x: 300, y: 300)
            center.position(x: 300, y: 300)
            dock.position(x: 300, y: 564).zIndex(3)

        }
        .frame(width: 600, height: 600)
        .scaleEffect(shown ? 1 : 0.94)
        .opacity(shown ? 1 : 0)
        .animation(reduceMotion ? nil : (state.presented ? .spring(response: 0.28, dampingFraction: 0.86) : .easeOut(duration: 0.1)), value: shown)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: state.selected)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: state.items)
        .onAppear { entrance.value = true }
    }

    private var center: some View {
        Button(action: cancel) {
            VStack(spacing: 5) {
                if state.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                    Text("Cancel").font(.system(size: 9, weight: .medium))
                }
            }
            .foregroundStyle(.secondary).frame(width: 92, height: 92)
            .background(KopiTheme.surface.opacity(reduceTransparency ? 1 : 0.42), in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
            .contentShape(Circle())
        }
        .buttonStyle(KopiPressStyle())
        .accessibilityLabel("Cancel radial clipboard")
        .zIndex(4)
    }

    private var dock: some View {
        VStack(spacing: 9) {
            HStack(spacing: 4) {
                Label("Recent", systemImage: "clock")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(KopiTheme.accent)
                    .padding(.horizontal, 12)
                Text(state.items.isEmpty ? state.message : "\(state.totalCount) clips").font(.system(size: 10)).foregroundStyle(.secondary)
                Divider().frame(height: 17).padding(.horizontal, 7)
                Button { page(-1) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 26) }
                    .disabled(state.page == 0 || state.loading).accessibilityLabel("Previous eight cards")
                Text("\(state.page + 1)/\(state.pageCount)").font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 25)
                Button { page(1) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 26) }
                    .disabled(state.page + 1 >= state.pageCount || state.loading).accessibilityLabel("Next eight cards")
            }
            .buttonStyle(.plain)
            .padding(5).background(KopiTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            Text(state.selectedItem == nil ? "\(state.trigger.title)  ·  Scroll / ← → older  ·  Esc cancel" : "Release to \(action)  ·  Return confirms  ·  Center cancels")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(KopiTheme.surface, in: Capsule())
        }.fixedSize()
    }
}

/// The focus vector is interpolated once for the whole wheel. Every frame
/// derives shared boundaries and fits content inside those exact boundaries.
private struct RadialWheel: View, Animatable {
    @ObservedObject var state: RadialState
    let previews: PreviewStore
    let choose: (Int) -> Void
    nonisolated var emphasis: RadialEmphasis
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let wheelSize = RadialGeometry.outerRadius * 2

    nonisolated var animatableData: RadialEmphasis {
        get { emphasis }
        set { emphasis = newValue }
    }

    var body: some View {
        let slices = RadialWheelLayout(count: state.items.count, emphasis: emphasis.values).slices
        ZStack {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                segment(item, slice: slices[index])
            }
        }
        .frame(width: wheelSize, height: wheelSize)
        .transaction { $0.animation = nil }
    }

    private func segment(_ item: ClipboardItemSummary, slice: RadialSlice) -> some View {
        let index = slice.index
        let angle = slice.centerAngle - .pi / 2
        let contentScale = 1 + (RadialGeometry.hoverScale - 1) * emphasis.weight(at: index)
        let selected = state.selected == index && !state.loading
        let shape = RadialSegment(slice: slice)
        let bounds = shape.path(in: CGRect(x: 0, y: 0, width: wheelSize, height: wheelSize)).boundingRect
        return Button { choose(index) } label: {
            ZStack {
                shape.fill((selected ? KopiTheme.selectedCardSurface : KopiTheme.cardSurface)
                    .opacity(reduceTransparency ? 1 : (selected ? 0.552 : 0.216)))
                if item.kind == .image {
                    RadialImagePreview(item: item, previews: previews, layout: RadialContentLayout(slice: slice), bounds: bounds, reduceTransparency: reduceTransparency)
                } else {
                    segmentText(item, slice: slice, scale: contentScale)
                }
                Text("\(index + 1)")
                    .font(.system(size: 10 * contentScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected ? KopiTheme.accent : .secondary)
                    .frame(width: 22, height: 22)
                    .position(x: 220 + cos(angle) * 67, y: 220 + sin(angle) * 67)
                shape.stroke(selected ? KopiTheme.accent : Color.primary.opacity(0.14), lineWidth: selected ? 1.5 : 0.75)
            }
            .frame(width: wheelSize, height: wheelSize)
            .clipShape(shape)
            .contentShape(shape)
            .opacity(state.loading ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .contentShape(shape)
        .disabled(state.loading)
        .accessibilityLabel("\(index + 1). \(state.copiesOnly ? "Copy" : "Paste") \(item.displayTitle)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .zIndex(selected ? 1 : 0)
        .position(x: wheelSize / 2, y: wheelSize / 2)
        .transition(reduceMotion ? .identity : .opacity)
    }

    private func segmentText(_ item: ClipboardItemSummary, slice: RadialSlice, scale: Double) -> some View {
        let layout = RadialContentLayout(slice: slice)
        let label = item.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = label.flatMap { $0.isEmpty ? nil : $0 } ?? (item.kind == .files ? item.displayTitle : item.excerpt)
        return Canvas { context, size in
            let lines = RadialTextFlow.lines(text, layout: layout, color: .labelColor, scale: scale)
            context.withCGContext { cg in
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                for line in lines {
                    let width = line.width
                    // Short snippets stay centered. Long paragraphs follow the
                    // wedge's changing left edge for more readable, fuller lines.
                    let inset = lines.count < 4 ? max(0, (line.rect.width - width) / 2) : 0
                    cg.textPosition = CGPoint(x: line.rect.minX + inset, y: size.height - line.rect.minY - 12 * scale)
                    CTLineDraw(line.text, cg)
                }
            }
        }
        .frame(width: wheelSize, height: wheelSize)
        .allowsHitTesting(false)
    }

}

private struct RadialEmphasis: VectorArithmetic, Sendable {
    var values = Array(repeating: 0.0, count: 8)
    static let zero = RadialEmphasis(selected: nil)

    init(selected: Int?) {
        if let selected, values.indices.contains(selected) { values[selected] = 1 }
    }

    func weight(at index: Int) -> Double { max(0, min(1, values[index])) }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    static func + (lhs: Self, rhs: Self) -> Self {
        var result = Self.zero
        result.values = zip(lhs.values, rhs.values).map(+)
        return result
    }
    static func - (lhs: Self, rhs: Self) -> Self {
        var result = Self.zero
        result.values = zip(lhs.values, rhs.values).map(-)
        return result
    }
}

/// Matches the controller's clockwise sectors, beginning at twelve o'clock.
/// The hole is the same size as the pointer's safe cancellation area.
struct RadialSegment: Shape {
    let slice: RadialSlice

    init(index: Int, count: Int) {
        slice = RadialWheelLayout(count: max(1, count)).slices[index]
    }
    init(slice: RadialSlice) { self.slice = slice }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let inner = radius * (RadialGeometry.cancelRadius / RadialGeometry.outerRadius)
        let sweep = slice.sweep
        let start = slice.startAngle - .pi / 2
        // A one-degree chord deviates from the circle by less than 0.01 pt.
        // Explicit contours avoid OS-dependent boolean-path hit-test results at
        // the hub's center, and need no live path subtraction during animation.
        let steps = max(2, Int(ceil(sweep / (.pi / 180))))
        func point(_ angle: Double, radius: Double) -> CGPoint {
            let x = cos(angle), y = sin(angle)
            return CGPoint(x: center.x + (abs(x) < 1e-10 ? 0 : x) * radius,
                           y: center.y + (abs(y) < 1e-10 ? 0 : y) * radius)
        }
        let outer = (0...steps).map { point(start + sweep * Double($0) / Double(steps), radius: radius) }
        let hole = (0...steps).reversed().map { point(start + sweep * Double($0) / Double(steps), radius: inner) }
        var path = Path()
        if let first = outer.first { path.move(to: first) }
        for point in outer.dropFirst() { path.addLine(to: point) }
        if slice.count <= 1 {
            path.closeSubpath()
            if let first = hole.first { path.move(to: first) }
            for point in hole.dropFirst() { path.addLine(to: point) }
        } else {
            for point in hole { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// A complete, sharp image, fitted to the actual available sector rather than
/// cropped into its bounding box. The surrounding glass stays consistent.
private struct RadialImagePreview: View {
    let item: ClipboardItemSummary
    let previews: PreviewStore
    let layout: RadialContentLayout
    let bounds: CGRect
    let reduceTransparency: Bool
    @ObservedObject private var entry: PreviewStore.Entry

    init(item: ClipboardItemSummary, previews: PreviewStore, layout: RadialContentLayout, bounds: CGRect, reduceTransparency: Bool) {
        self.item = item
        self.previews = previews
        self.layout = layout
        self.bounds = bounds
        self.reduceTransparency = reduceTransparency
        entry = previews.entry(for: item.id)
    }

    var body: some View {
        let aspect = entry.image.map { Double($0.width) / Double(max(1, $0.height)) } ?? 1.5
        let rect = layout.imageRect(aspectRatio: aspect)
        ZStack {
            if let image = entry.image {
                if !reduceTransparency {
                    // Only a soft wash reaches the wedge edges. The sharp preview
                    // remains complete and the background never competes with it.
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: bounds.width, height: bounds.height)
                        .clipped().blur(radius: 22).opacity(0.19)
                        .position(x: bounds.midX, y: bounds.midY)
                }
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
                    .position(x: rect.midX, y: rect.midY)
            } else {
                Image(systemName: "photo").font(.system(size: 25)).foregroundStyle(.secondary)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: RadialGeometry.outerRadius * 2, height: RadialGeometry.outerRadius * 2)
        .accessibilityLabel("Image preview")
        .task(id: item.fingerprint) { await previews.load(item, maxPixelSize: 640) }
    }
}
