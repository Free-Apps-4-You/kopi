import SwiftUI
import KopiCore

/// Adjoining annular segments form one wheel around the cancel/preview hub.
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
    private var active: ClipboardItemSummary? { state.selectedItem }
    private var action: String { state.copiesOnly ? "copy" : "paste" }

    var body: some View {
        ZStack {
            Circle().fill(KopiTheme.surface.opacity(reduceTransparency ? 1 : 0.25))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 9)
                .frame(width: 456, height: 456).position(x: 300, y: 300)
                .allowsHitTesting(false)
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                segment(item, index: index)
            }
            center.position(x: 300, y: 300)
            dock.position(x: 300, y: 564)
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28)
                    .background(KopiTheme.cardSurface, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
            }.buttonStyle(KopiPressStyle()).accessibilityLabel("Cancel radial clipboard")
                .position(x: 300, y: 51)
        }
        .frame(width: 600, height: 600)
        .scaleEffect(shown ? 1 : 0.94)
        .opacity(shown ? 1 : 0)
        .animation(reduceMotion ? nil : (state.presented ? .spring(response: 0.28, dampingFraction: 0.86) : .easeOut(duration: 0.1)), value: shown)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: state.selected)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: state.items)
        .onAppear { entrance.value = true }
    }

    private func segment(_ item: ClipboardItemSummary, index: Int) -> some View {
        let count = max(1, state.items.count)
        let angle = Double(index) * 2 * .pi / Double(count) - .pi / 2
        let selected = state.selected == index && !state.loading
        let shape = RadialSegment(index: index, count: count)
        return Button { choose(index) } label: {
            ZStack {
                shape.fill((selected ? KopiTheme.selectedCardSurface : KopiTheme.cardSurface).opacity(reduceTransparency ? 1 : (selected ? 0.64 : 0.3)))
                shape.stroke(selected ? KopiTheme.accent.opacity(0.75) : Color.primary.opacity(0.09), lineWidth: selected ? 1.5 : 1)
                segmentLabel(item, index: index, selected: selected)
                    .position(x: 228 + cos(angle) * 158, y: 228 + sin(angle) * 158)
            }
            .frame(width: 456, height: 456)
            .clipShape(shape)
            .contentShape(shape)
            .opacity(state.loading ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .contentShape(shape)
        .disabled(state.loading)
        .accessibilityLabel("\(index + 1). \(state.copiesOnly ? "Copy" : "Paste") \(item.displayTitle)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .position(x: 300, y: 300)
        .transition(reduceMotion ? .identity : .opacity)
    }

    private func segmentLabel(_ item: ClipboardItemSummary, index: Int, selected: Bool) -> some View {
        VStack(spacing: 7) {
            if item.kind == .image {
                RadialImageThumbnail(item: item, previews: previews).frame(width: 64, height: 40)
            } else {
                RadialGlyph(item: item).frame(width: 25, height: 25)
            }
            Text(item.kind == .image ? "Image" : item.displayTitle).font(.system(size: 11, weight: selected ? .semibold : .medium))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 96, height: 28)
            HStack(spacing: 4) {
                if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
                Text("\(index + 1)").font(.system(size: 9, weight: .semibold, design: .rounded))
            }.foregroundStyle(.secondary)
        }
        .foregroundStyle(selected ? KopiTheme.accent : .primary)
        .frame(width: 104, height: 82)
    }

    private var center: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(KopiTheme.accent).frame(width: 5, height: 5)
                Text("RECENT").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.1)
            }.foregroundStyle(KopiTheme.accent)
            if state.loading {
                ProgressView().controlSize(.small).frame(height: 34)
                Text("Finding your clips…").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let item = active {
                if item.kind == .image {
                    RadialImageThumbnail(item: item, previews: previews).frame(width: 124, height: 62)
                } else {
                    Text(String((item.excerpt.isEmpty ? item.displayTitle : item.excerpt).prefix(160)))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(3)
                        .multilineTextAlignment(.center).frame(height: 43)
                }
                Text(item.domain ?? item.sourceApp?.displayName ?? item.kind.displayName)
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                Text("Release to \(action)").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(KopiTheme.accent)
            } else {
                Text(state.items.isEmpty ? "Nothing here yet" : "Ready when you are")
                    .font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
                Text(state.items.isEmpty ? state.message : "Point to a clip\nCenter cancels")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
            }
        }
        .padding(15).frame(width: 166, height: 166)
        .background(KopiTheme.surface.opacity(reduceTransparency ? 1 : 0.55), in: Circle())
        .overlay(Circle().strokeBorder(active == nil ? Color.primary.opacity(0.09) : KopiTheme.accent.opacity(0.45)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var dock: some View {
        VStack(spacing: 9) {
            HStack(spacing: 4) {
                Label("Recent", systemImage: "clock")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(KopiTheme.accent)
                    .padding(.horizontal, 12)
                Text("\(state.totalCount) clips").font(.system(size: 10)).foregroundStyle(.secondary)
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
            Text("\(state.trigger.title)  ·  Scroll / ← → older  ·  Esc cancel")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(KopiTheme.surface, in: Capsule())
        }.fixedSize()
    }
}

private struct RadialGlyph: View {
    let item: ClipboardItemSummary
    var body: some View {
        if let color = ClipboardColor.parse(item.excerpt) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                .accessibilityLabel(color.hexString)
        } else {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(KopiTheme.accent)
        }
    }
    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .link: "link"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}

/// Matches the controller's clockwise sectors, beginning at twelve o'clock.
/// The hole is the same size as the pointer's safe cancellation area.
struct RadialSegment: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let inner = radius * (88.0 / 228.0)
        let hole = Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner,
                                         width: inner * 2, height: inner * 2))
        if count <= 1 { return Path(ellipseIn: rect).subtracting(hole) }
        let sweep = 360.0 / Double(count)
        let start = Angle.degrees(Double(index) * sweep - 90 - sweep / 2)
        let end = Angle.degrees(Double(index) * sweep - 90 + sweep / 2)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        return path.subtracting(hole)
    }
}

/// Uses the same bounded, asynchronous image cache as the main clipboard grid.
private struct RadialImageThumbnail: View {
    let item: ClipboardItemSummary
    let previews: PreviewStore
    @ObservedObject private var entry: PreviewStore.Entry

    init(item: ClipboardItemSummary, previews: PreviewStore) {
        self.item = item
        self.previews = previews
        entry = previews.entry(for: item.id)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06))
            if let image = entry.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .padding(2)
            } else {
                Image(systemName: "photo").font(.system(size: 19)).foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel("Image preview")
        .task(id: item.fingerprint) { await previews.load(item, maxPixelSize: 320) }
    }
}
