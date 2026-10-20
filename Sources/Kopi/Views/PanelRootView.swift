import SwiftUI
import KopiCore

/// The panel: the main and sub chip rows, search, cards, and the preview and editor
/// overlays.
struct PanelRootView: View {
    @ObservedObject var model: PanelViewModel
    let commands: PanelCommands
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A drag resting over the collection.
    @StateObject private var collectTargeted = PanelState(false)
    @StateObject private var closeHover = PanelState(false)

    var body: some View {
        panel
            .padding(KopiTheme.shadowInset)
            .environment(\.kopiCompactCards, model.usesCompactCards)

            .alert("Save changes before leaving?", isPresented: $model.showsSavePrompt) {
                Button("Save") { Task { await model.saveAndContinue() } }
                Button("Discard Changes", role: .destructive) { model.discardAndContinue() }.disabled(model.isSavingDraft)
                Button("Keep Editing", role: .cancel) { model.cancelPendingNavigation() }
            } message: { Text("Save your item, discard the draft, or keep editing.") }
            .onChange(of: model.queryText) { _, value in
                model.notes.searchText = model.section == .notes ? value : ""
            }
            .onChange(of: model.section) { _, section in
                model.notes.searchText = section == .notes ? model.queryText : ""
            }

    }

    /// The whole panel: the body under the menu bar, and the neck that reaches a
    /// notched display's top edge. Surface, neck, border, shadow and content all take
    /// their place together when the panel opens, growing from the top centre.
    private var panel: some View {
        VStack(spacing: 0) {
            neckSpacer
            card
        }
        .background(PanelSurface())
        .clipShape(panelOutline)
        .overlay(panelOutline.strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1))
        .background(panelShadow)

    }

    /// Room above the body for the neck to the camera housing; zero without one.
    private var neckSpacer: some View {
        Color.clear.frame(height: neckHeight)
    }

    private var neckHeight: CGFloat {
        model.panelAttachment?.neckHeight ?? 0
    }

    private var panelOutline: PanelOutline {
        PanelOutline(cornerRadius: KopiTheme.panelCornerRadius, attachment: model.panelAttachment)
    }

    /// The body's own shadow, kept off the neck so no glow gathers around the housing.
    private var panelShadow: some View {
        VStack(spacing: 0) {
            neckSpacer
            RoundedRectangle(cornerRadius: KopiTheme.panelCornerRadius, style: .continuous)
                .fill(KopiTheme.surface)
                .shadow(
                    color: KopiTheme.Elevation.panelColor,
                    radius: KopiTheme.Elevation.panelRadius,
                    y: KopiTheme.Elevation.panelY
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Previews and editors, on the body rather than on the strip the neck takes
    /// above it.
    private var bodyOverlays: some View {
        overlays
    }

    /// The body of the panel: the header, the search area, the cards and the footer.
    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(KopiTheme.border(contrast: contrast))
            GeometryReader { proxy in
                HStack(spacing: 10) {
                    if model.section != .notes {
                        Button { model.addItem() } label: { Image(systemName: "plus") }
                            .buttonStyle(KopiIconButtonStyle()).accessibilityLabel("Add item").kopiTooltip("Add item")
                    }
                    Button { model.goHome() } label: { Image(systemName: "house.fill") }
                        .buttonStyle(KopiIconButtonStyle()).accessibilityLabel("Home — All items").kopiTooltip("Home — All items")
                    PanelSearchField(text: $model.queryText, prompt: searchPrompt, focusRequest: model.focusRequest)
                        .frame(width: max(100, (model.section.showsClipboardCards ? proxy.size.width - 380 : min(500, proxy.size.width - 80)) * 2 / 3))
                    if model.section.showsClipboardCards {
                        SourceAppFilter(model: model)
                    }
                    Spacer(minLength: 10)
                    if model.section.showsClipboardCards {
                        SourceChips(selection: model.source) { source in
                            model.toggleSource(source)
                        } onDropContent: { providers in
                            model.collectDropped(providers)
                        }
                        .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 28)
            .padding(.horizontal, KopiTheme.contentPadding)
            .padding(.vertical, 8)
            .background(KopiTheme.surfaceHighlight.opacity(0.35))
            VStack(spacing: 0) {
            content
            Divider().overlay(KopiTheme.border(contrast: contrast))
            PanelStatusBar(hints: hints, status: model.statusMessage, captureState: model.captureState)
            }
            .modifier(PanelFocusEffect(model: model, notes: model.notes, passwords: model.passwords))
            .overlay { bodyOverlays }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Kopi")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .tracking(-0.35)
                .foregroundStyle(.primary)
                .padding(.trailing, 5)
                .accessibilityAddTraits(.isHeader)
            SectionChips(selection: model.section) { section in
                model.setSection(section)
            }
            Spacer(minLength: 8)
            PanelSettingsControl(action: commands.openSettings)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(KopiTheme.controlSurface))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .kopiTooltip("Kopi Settings")
            .accessibilityLabel("Open Kopi settings")
            if model.showsCloseButton {
                closeButton
            }
        }
        .padding(.horizontal, KopiTheme.contentPadding)
        .padding(.vertical, 9)
        .background {
            LinearGradient(colors: [KopiTheme.surfaceHighlight, .clear], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Offered while clicking outside no longer dismisses the panel, so there is always
    /// a way out besides Escape.
    private var closeButton: some View {
        Button {
            commands.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(closeHover.value ? Color.primary : Color.secondary)
                .padding(6)
                .background(Circle().fill(Color.primary.opacity(closeHover.value ? 0.12 : 0.06)))
        }
        .buttonStyle(KopiPressStyle())
        .onHover { closeHover.value = $0 }
        .animation(KopiMotion.animation(KopiMotion.hover, reduceMotion: reduceMotion), value: closeHover.value)
        .accessibilityLabel("Close Kopi").kopiTooltip("Close Kopi")
    }

    /// The grid of the selected section, or the Notes section. Each section keeps its
    /// own identity so a change of kind reads as a transition rather than a snap; a
    /// change of source only reloads the same grid. The collection takes drops of
    /// content from other applications, from Finder, and of cards of another chip.
    private var content: some View {
        ZStack {
            if model.section == .notes {
                NotesTabView(model: model.notes, commands: commands)
                    .id(PanelSection.notes)
                    .transition(.identity)
            } else if model.section == .passwords {
                PasswordsTabView(model: model.passwords, query: model.queryText)
            } else {
                ClipboardTabView(model: model, commands: commands, scope: model.listScope)
                    .id(model.section)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        .onDrop(
            of: model.isShowingCollection ? DroppedContent.supportedTypes : [],
            isTargeted: $collectTargeted.value
        ) { providers in
            guard model.isShowingCollection else { return false }
            model.collectDropped(providers)
            return true
        }
        .overlay { collectHighlight }
        .animation(KopiMotion.animation(KopiMotion.hover, reduceMotion: reduceMotion), value: collectTargeted.value)
    }

    /// Shown while a drag rests over the collection: an outline that reads as a drop
    /// target without moving anything on screen.
    @ViewBuilder
    private var collectHighlight: some View {
        if collectTargeted.value {
            RoundedRectangle(cornerRadius: KopiTheme.overlayCornerRadius, style: .continuous)
                .strokeBorder(KopiTheme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .padding(KopiTheme.contentPadding + 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var overlays: some View {
        ZStack {
            if model.preview != nil {
                PreviewOverlay(model: model, commands: commands)
                    .transition(overlayTransition)
            }
            if model.editor != nil {
                ClipboardEditorView(model: model)
                    .transition(overlayTransition)
            }
            NewItemComposerView(model: model)
            PasswordComposerView(model: model.passwords)
            if model.section == .notes {
                NotesPanelOverlays(model: model.notes, commands: commands)
            }
        }
        .animation(KopiMotion.animation(KopiMotion.overlay, reduceMotion: reduceMotion), value: model.preview?.itemID)
        .animation(KopiMotion.animation(KopiMotion.overlay, reduceMotion: reduceMotion), value: model.editor?.itemID)
    }

    private var contentTransition: AnyTransition {
        KopiMotion.transition(.opacity, reduceMotion: reduceMotion)
    }

    private var overlayTransition: AnyTransition {
        KopiMotion.transition(.kopiSurface, reduceMotion: reduceMotion)
    }

    private var searchPrompt: String {
        if model.section == .passwords { return "Search passwords by title" }
        if model.section == .notes { return "Search notes" }
        switch model.source {
        case .pinned: return "Search pinned cards"
        case .collection: return "Search collection"
        case nil: return "Search clipboard history"
        }
    }

    private var hints: String {
        if model.section == .passwords { return "Passwords are encrypted · Show requires macOS authentication · Hidden again after 20 seconds" }
        if model.section == .notes {
            return "Click copies · Return pastes · Space maximises · ⌘C copies · Drag to another app"
        }
        if model.source == .collection {
            return "Click copies · Return pastes · ⌘V collects · Space previews · ⌘E edits"
        }
        let pinHint = model.source == .pinned ? "⌘P unpins" : "⌘P pins"
        return "Click copies · Return pastes · ⌘C copies · Space previews · ⌘E edits · \(pinHint) · ⌘1–9 pastes"
    }
}

/// Observe Notes directly. Observing PanelViewModel does not subscribe to changes
/// in its nested Notes model, so those changes previously left overlays invisible.
private struct NotesPanelOverlays: View {
    @ObservedObject var model: NotesTabViewModel
    let commands: PanelCommands
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.composer != nil {
                NotesComposerView(model: model)
                    .transition(KopiMotion.transition(.kopiSurface, reduceMotion: reduceMotion))
            }
            if model.preview != nil {
                NotesPreviewView(model: model, commands: commands)
                    .transition(KopiMotion.transition(.kopiSurface, reduceMotion: reduceMotion))
            }
        }
        .animation(KopiMotion.animation(KopiMotion.overlay, reduceMotion: reduceMotion), value: model.composer?.id)
        .animation(KopiMotion.animation(KopiMotion.overlay, reduceMotion: reduceMotion), value: model.preview?.id)
    }
}

/// Blur the app's actual content, rather than filling the preview with unused space.
private struct PanelFocusEffect: ViewModifier {
    @ObservedObject var model: PanelViewModel
    @ObservedObject var notes: NotesTabViewModel
    @ObservedObject var passwords: PasswordsViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var focused: Bool {
        model.preview != nil || model.editor != nil || model.newItemDraft != nil || notes.preview != nil || notes.composer != nil || passwords.draft != nil
    }
    func body(content: Content) -> some View {
        content
            .blur(radius: focused && !reduceTransparency ? 7 : 0)
            .allowsHitTesting(!focused)
            .accessibilityHidden(focused)
    }
}
