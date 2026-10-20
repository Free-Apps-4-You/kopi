import SwiftUI
import CopilyCore

/// The main row of the panel: All, Text, Links, Images, Files and the Notes section,
/// with one sliding selection indicator, hover feedback and the same keyboard and
/// accessibility behaviour as before. Notes carries the Apple logo beside its label.
struct SectionChips: View {
    let selection: PanelSection
    let onSelect: (PanelSection) -> Void
    @Namespace private var indicator
    @StateObject private var hoveredChip = PanelState<PanelSection?>(nil)
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PanelSection.allCases) { section in
                Button {
                    onSelect(section)
                } label: {
                    label(section)
                }
                .buttonStyle(CopilyPressStyle())
                .onHover { inside in
                    hoveredChip.value = inside ? section : (hoveredChip.value == section ? nil : hoveredChip.value)
                }
                .accessibilityLabel(section.showsClipboardCards ? "Show \(section.displayName) cards" : "\(section.displayName) section")
                .copilyTooltip(section.displayName)
                .accessibilityAddTraits(selection == section ? [.isSelected] : [])
            }
        }
        .animation(CopilyMotion.animation(CopilyMotion.indicator, reduceMotion: reduceMotion), value: selection)
        .animation(CopilyMotion.animation(CopilyMotion.hover, reduceMotion: reduceMotion), value: hoveredChip.value)
    }

    private func label(_ section: PanelSection) -> some View {
        HStack(spacing: 6) {
            if section == .notes || section == .passwords {
                Image(systemName: section == .notes ? "apple.logo" : "key.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            Text(section.displayName)
                .font(.system(size: 11.5, weight: selection == section ? .semibold : .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5.5)
        .foregroundStyle(selection == section ? CopilyTheme.accent : Color.secondary)
        .background {
            if selection == section {
                RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius, style: .continuous)
                    .fill(CopilyTheme.accent.opacity(contrast == .increased ? 0.24 : 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius, style: .continuous)
                            .strokeBorder(CopilyTheme.accent.opacity(contrast == .increased ? 0.60 : 0.22), lineWidth: 1)
                    )
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(CopilyTheme.accent.opacity(0.85))
                            .frame(width: 14, height: 2)
                            .padding(.bottom, 1)
                    }
                    .matchedGeometryEffect(id: "sectionSelection", in: indicator)
            } else if hoveredChip.value == section {
                RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius, style: .continuous))
    }
}

/// The sub row of the panel, beneath the search field: pinned cards or the collection
/// shelf. Neither chip selected is ordinary history, and picking the selected chip
/// again returns to it. The Collection chip also takes a drop of a card of another chip,
/// or of content from another application.
struct SourceChips: View {
    let selection: PanelSource?
    let onSelect: (PanelSource) -> Void
    var onDropContent: (([NSItemProvider]) -> Void)?
    @Namespace private var indicator
    @StateObject private var hoveredChip = PanelState<PanelSource?>(nil)
    @StateObject private var dropTargeted = PanelState(false)
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PanelSource.allCases) { source in
                Button {
                    onSelect(source)
                } label: {
                    label(source)
                }
                .buttonStyle(CopilyPressStyle())
                .onHover { inside in
                    hoveredChip.value = inside ? source : (hoveredChip.value == source ? nil : hoveredChip.value)
                }
                .onDrop(
                    of: source == .collection ? DroppedContent.supportedTypes : [],
                    isTargeted: $dropTargeted.value
                ) { providers in
                    guard source == .collection, let onDropContent else { return false }
                    onDropContent(providers)
                    return true
                }
                .overlay {
                    if source == .collection, dropTargeted.value {
                        Capsule().strokeBorder(
                            CopilyTheme.accent,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])
                        )
                    }
                }
                .accessibilityLabel("Show \(source.displayName.lowercased()) cards")
                .copilyTooltip(source.displayName)
                .accessibilityAddTraits(selection == source ? [.isSelected] : [])
                .accessibilityHint(selection == source ? "Press again to show all history" : "Shows only \(source.displayName.lowercased()) cards")
            }
        }
        .animation(CopilyMotion.animation(CopilyMotion.indicator, reduceMotion: reduceMotion), value: selection)
        .animation(CopilyMotion.animation(CopilyMotion.hover, reduceMotion: reduceMotion), value: hoveredChip.value)
    }

    private func label(_ source: PanelSource) -> some View {
        Label(source.displayName, systemImage: source == .pinned ? "pin.fill" : "tray.full.fill")
            .font(.system(size: 11, weight: selection == source ? .semibold : .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 3.5)
            .foregroundStyle(selection == source ? CopilyTheme.accent : Color.secondary)
            .background {
                if selection == source {
                    Capsule()
                        .fill(CopilyTheme.accent.opacity(contrast == .increased ? 0.24 : 0.10))
                        .overlay(
                            Capsule().strokeBorder(
                                CopilyTheme.accent.opacity(contrast == .increased ? 0.70 : 0.30),
                                lineWidth: 1
                            )
                        )
                        .matchedGeometryEffect(id: "sourceSelection", in: indicator)
                } else {
                    Capsule()
                        .fill(CopilyTheme.controlSurface)
                        .overlay(Capsule().fill(Color.primary.opacity(hoveredChip.value == source ? 0.045 : 0)))
                        .overlay(Capsule().strokeBorder(CopilyTheme.border(contrast: contrast), lineWidth: 0.75))
                }
            }
            .contentShape(Capsule())
    }
}

/// The collection's New Item affordance: a persistent button beside the sub chips, and
/// the action of the empty collection state. It creates the card and opens the editor.
struct NewCollectionItemButton: View {
    let action: () -> Void
    @StateObject private var hover = PanelState(false)
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("New Item")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .foregroundStyle(CopilyTheme.accent)
            .background(Capsule().fill(CopilyTheme.accent.opacity(fillOpacity)))
            .overlay(Capsule().strokeBorder(CopilyTheme.accent.opacity(borderOpacity), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(CopilyPressStyle())
        .onHover { hover.value = $0 }
        .animation(CopilyMotion.animation(CopilyMotion.hover, reduceMotion: reduceMotion), value: hover.value)
        .accessibilityLabel("New collection item")
        .accessibilityHint("Creates a card and opens it in the editor")
        .copilyTooltip("Create a new collection item")
    }

    private var fillOpacity: Double {
        hover.value ? 0.18 : 0.10
    }

    private var borderOpacity: Double {
        hover.value ? (contrast == .increased ? 0.80 : 0.45) : (contrast == .increased ? 0.65 : 0.28)
    }
}

/// Type indicator on a card.
struct KindBadge: View {
    let kind: ClipboardItemKind
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(for: kind))
                .font(.system(size: 9, weight: .semibold))
            Text(kind.displayName)
                .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.13 : 0.045)))
        .overlay(Capsule().strokeBorder(CopilyTheme.border(contrast: contrast).opacity(0.65), lineWidth: 0.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .copilyTooltip(kind.displayName)
    }

    static func symbol(for kind: ClipboardItemKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .link: "link"
        case .image: "photo"
        case .files: "folder"
        }
    }
}

/// Quiet shortcut hint of a card: ⌘1 through ⌘9 paste the first nine cards.
struct QuickPasteBadge: View {
    let position: Int
    var isProminent: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text("⌘\(position)")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(CopilyTheme.chipSurface))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(CopilyTheme.border(contrast: contrast), lineWidth: 0.5))
            .opacity(isProminent ? 1 : 0.65)
            .copilyTooltip("Paste item \(position) with ⌘\(position)")
            .accessibilityHidden(true)
    }
}

/// Larger call to action of the empty and failure states.
struct StatePanel: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 12) {
            symbolMark
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CopilyTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(CopilyTheme.accent.opacity(contrast == .increased ? 0.22 : 0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CopilyTheme.accent.opacity(contrast == .increased ? 0.65 : 0.28), lineWidth: 1))
                }
                .buttonStyle(CopilyPressStyle())
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var symbolMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(CopilyTheme.accent.opacity(contrast == .increased ? 0.18 : 0.075))
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(CopilyTheme.accent.opacity(contrast == .increased ? 0.45 : 0.18), lineWidth: 1)
            Image(systemName: symbol).copilyTooltip(title)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(CopilyTheme.accent)
        }
        .frame(width: 54, height: 54)
    }
}

/// Search field beneath the tabs, scoped to the selected tab.
struct PanelSearchField: View {
    @Binding var text: String
    let prompt: String
    /// Bumped by the view model when the panel opens, which claims the keyboard.
    var focusRequest: Int = 0
    @StateObject private var focusedState = PanelState(false)
    private var isFocused: Bool { focusedState.value }
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").copilyTooltip("Search")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isFocused ? CopilyTheme.accent : Color.secondary)
            PanelSearchInput(text: $text, prompt: prompt, focusRequest: focusRequest) {
                focusedState.value = $0
            }
            .frame(height: 18)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CopilyPressStyle())
                .accessibilityLabel("Clear search").copilyTooltip("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius, style: .continuous)
                .fill(CopilyTheme.insetSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius, style: .continuous)
                .strokeBorder(
                    isFocused ? CopilyTheme.accent.opacity(contrast == .increased ? 0.85 : 0.60) : CopilyTheme.border(contrast: contrast),
                    lineWidth: 1
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: CopilyTheme.controlCornerRadius + 2, style: .continuous)
                .strokeBorder(CopilyTheme.accent.opacity(isFocused ? (contrast == .increased ? 0.22 : 0.12) : 0), lineWidth: 2)
                .padding(-2)
                .allowsHitTesting(false)
        }
        .animation(CopilyMotion.animation(CopilyMotion.hover, reduceMotion: reduceMotion), value: isFocused)

    }
}

/// An AppKit field can explicitly reclaim first responder on every window opening.
struct PanelSearchInput: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let focusRequest: Int
    let onFocus: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier("copily.search")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(prompt)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        guard context.coordinator.focusRequest != focusRequest else { return }
        context.coordinator.focusRequest = focusRequest
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window, window.isKeyWindow else { return }
            window.makeFirstResponder(field)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelSearchInput
        var focusRequest = -1
        init(parent: PanelSearchInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocus(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onFocus(false) }
    }
}

/// Bottom strip of the panel: the keyboard hints and the last action's outcome.
struct PanelStatusBar: View {
    let hints: String
    let status: PanelViewModel.StatusMessage?
    let captureState: ClipboardCaptureState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            captureIndicator
            Spacer(minLength: 8)
            if let status {
                statusLabel(status)
                    .layoutPriority(1)
                    .transition(CopilyMotion.transition(.copilySurface, reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, CopilyTheme.contentPadding + 2)
        .padding(.vertical, 7)
        .background(CopilyTheme.insetSurface.opacity(0.55))
        .animation(CopilyMotion.animation(CopilyMotion.status, reduceMotion: reduceMotion), value: status)
    }

    private func statusLabel(_ status: PanelViewModel.StatusMessage) -> some View {
        HStack(spacing: 5) {
            Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").copilyTooltip(status.isError ? "Error" : "Done")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(status.text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .copilyTooltip(status.text)
        }
        .foregroundStyle(status.isError ? Color.orange : CopilyTheme.accent)
    }

    /// Explain a paused or blocked capture loop before offering keyboard hints.
    @ViewBuilder
    private var captureIndicator: some View {
        if let block = captureState.block {
            Label(block.displayName, systemImage: "exclamationmark.triangle").copilyTooltip(block.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange)
        } else if case .paused(let reason) = captureState {
            Label(reason.displayName, systemImage: "pause.circle")
                .copilyTooltip(reason == .captureDisabled ? "Resume saving copies in Settings → History" : "Capture paused during sleep")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            Text(hints)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .copilyTooltip(hints)
        }
    }
}
