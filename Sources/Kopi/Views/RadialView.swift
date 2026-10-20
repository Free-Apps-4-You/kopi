import SwiftUI
import KopiCore

/// Opaque floating surfaces keep the animated wheel stable over every desktop.
struct RadialView: View {
    @ObservedObject var state: RadialState
    let choose: (Int) -> Void
    let ring: (Int) -> Void
    let page: (Int) -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var entrance = PanelState(false)

    private var shown: Bool { entrance.value && state.presented }
    private var active: ClipboardItemSummary? { state.selectedItem }
    private var action: String { state.copiesOnly ? "copy" : "paste" }

    var body: some View {
        ZStack {
            Circle().strokeBorder(KopiTheme.accent.opacity(0.12), lineWidth: 1)
                .frame(width: 356, height: 356).position(x: 300, y: 300)
                .allowsHitTesting(false)
            if let selected = state.selected, !state.loading {
                let angle = Double(selected) * 2 * .pi / Double(max(1, state.items.count)) - .pi / 2
                Path { path in
                    path.move(to: CGPoint(x: 300 + cos(angle) * 92, y: 300 + sin(angle) * 92))
                    path.addLine(to: CGPoint(x: 300 + cos(angle) * 132, y: 300 + sin(angle) * 132))
                }.stroke(KopiTheme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .transition(.opacity).allowsHitTesting(false)
            }
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                petal(item, index: index)
            }
            center.position(x: 300, y: 300)
            dock.position(x: 300, y: 560)
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

    private func petal(_ item: ClipboardItemSummary, index: Int) -> some View {
        let angle = Double(index) * 2 * .pi / Double(max(1, state.items.count)) - .pi / 2
        let selected = state.selected == index && !state.loading
        return Button { choose(index) } label: {
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    RadialGlyph(item: item).frame(width: 23, height: 23)
                    Spacer(minLength: 0)
                    if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
                    Text("\(index + 1)").font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary).frame(width: 17, height: 17)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                Text(item.displayTitle).font(.system(size: 11, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .topLeading)
            }
            .padding(11)
            .frame(width: 108, height: 88)
            .foregroundStyle(selected ? KopiTheme.accent : .primary)
            .background(selected ? KopiTheme.selectedCardSurface : KopiTheme.cardSurface,
                        in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(selected ? KopiTheme.accent.opacity(0.9) : Color.primary.opacity(0.09), lineWidth: selected ? 1.5 : 1))
            .shadow(color: selected ? KopiTheme.accent.opacity(0.14) : .black.opacity(0.11), radius: selected ? 13 : 8, y: selected ? 3 : 5)
            .scaleEffect(selected ? 1.055 : 1)
            .opacity(state.loading ? 0.35 : 1)
        }
        .buttonStyle(KopiPressStyle())
        .disabled(state.loading)
        .accessibilityLabel("\(index + 1). \(state.copiesOnly ? "Copy" : "Paste") \(item.displayTitle)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .position(x: 300 + cos(angle) * (shown ? 178 : 166), y: 300 + sin(angle) * (shown ? 178 : 166))
        .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.92)))
    }

    private var center: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(KopiTheme.accent).frame(width: 5, height: 5)
                Text(state.names[state.ring].uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.1)
            }.foregroundStyle(KopiTheme.accent)
            if state.loading {
                ProgressView().controlSize(.small).frame(height: 34)
                Text("Finding your clips…").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let item = active {
                Text(String((item.excerpt.isEmpty ? item.displayTitle : item.excerpt).prefix(160))).font(.system(size: 12, weight: .semibold)).lineLimit(3)
                    .multilineTextAlignment(.center).frame(height: 43)
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
        .background(KopiTheme.surface, in: Circle())
        .overlay(Circle().strokeBorder(active == nil ? Color.primary.opacity(0.09) : KopiTheme.accent.opacity(0.45)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var dock: some View {
        VStack(spacing: 9) {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Button { ring(index) } label: {
                        Label(state.names[index], systemImage: ["clock", "pin", "tray.full"][index])
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .foregroundStyle(state.ring == index ? KopiTheme.accent : .secondary)
                            .background(state.ring == index ? KopiTheme.accentWash : .clear, in: Capsule())
                    }.buttonStyle(KopiPressStyle()).accessibilityAddTraits(state.ring == index ? [.isSelected] : [])
                }
                Divider().frame(height: 17).padding(.horizontal, 4)
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
            Text("\(state.trigger.title)  ·  Scroll rings  ·  ← → more  ·  Esc cancel")
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
