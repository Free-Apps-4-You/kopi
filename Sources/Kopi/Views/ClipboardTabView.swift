import SwiftUI
import KopiCore

/// Card grid of one section, three or four columns depending on the panel width.
struct ClipboardTabView: View {
    @ObservedObject var model: PanelViewModel
    let commands: PanelCommands
    let scope: HistoryScope
    @Environment(\.kopiCompactCards) private var compactCards

    var body: some View {
        let page = model.page(for: scope)
        Group {
            if page.isLoading && !page.hasLoaded {
                loadingState
            } else if let error = page.error {
                StatePanel(
                    symbol: "exclamationmark.triangle",
                    title: "History unavailable",
                    message: error,
                    actionTitle: "Try Again"
                ) {
                    Task { await model.reload(scope) }
                }
            } else if page.isEmpty {
                emptyState
            } else {
                grid(page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Columns of the grid, which the loading skeletons share so nothing shifts when
    /// the cards arrive.
    static func columns(for width: CGFloat, compact: Bool = false) -> [GridItem] {
        let count = PanelGeometry.columnCount(forPanelWidth: width + KopiTheme.contentPadding * 2, compact: compact)
        return Array(repeating: GridItem(.flexible(), spacing: KopiTheme.cardSpacing), count: count)
    }

    private var loadingState: some View {
        GeometryReader { proxy in
            SkeletonCardGrid(columns: Self.columns(for: proxy.size.width, compact: compactCards))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .accessibilityElement()
        .accessibilityLabel("Loading cards")
    }

    @ViewBuilder
    private var emptyState: some View {
        let searching = !model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if searching {
            StatePanel(
                symbol: "magnifyingglass",
                title: "No matches",
                message: "No cards match “\(model.queryText)”.",
                actionTitle: "Clear Search"
            ) {
                model.queryText = ""
            }
        } else if model.sourceAppBundleIdentifier != nil {
            StatePanel(
                symbol: "app.dashed", title: "No matching cards from this app",
                message: "Try another content type or show cards from all apps.",
                actionTitle: "Show All Apps"
            ) { model.setSourceApp(nil) }
        } else if scope == .pinned {
            StatePanel(
                symbol: "pin",
                title: "No pinned cards",
                message: "Pin a card with ⌘P to keep it here, out of the reach of retention and Clear History."
            )
        } else if scope == .collection {
            StatePanel(
                symbol: "tray.full",
                title: "No collected cards",
                message: "Create an item, paste, or drop something here.",
                actionTitle: "New Item"
            ) {
                model.addItem()
            }
        } else {
            StatePanel(
                symbol: "doc.on.clipboard",
                title: "No clipboard cards yet",
                message: "Copy something and it appears here, ready to paste again."
            )
        }
    }

    private func grid(_ page: PanelViewModel.Page) -> some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: Self.columns(for: proxy.size.width, compact: compactCards), spacing: KopiTheme.cardSpacing) {
                    ForEach(Array(page.items.enumerated()), id: \.element.id) { index, item in
                        ClipboardCardView(
                            item: item,
                            position: index + 1,
                            model: model,
                            previews: model.previews,
                            commands: commands,
                            isSelected: model.selection == item.id,
                            isExpanded: model.isExpanded(item.id)
                        )
                        .id(item.id)
                        .onAppear {
                            model.loadMoreIfNeeded(item)
                        }
                        .task(id: item.fingerprint) { await model.previews.load(item) }
                    }
                }
                .padding(.horizontal, KopiTheme.contentPadding)
                .padding(.top, 4)
                .padding(.bottom, 10)

                if page.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 12)
                } else if page.hasMore {
                    Button("Load more") {
                        guard let last = page.items.last else { return }
                        model.loadMoreIfNeeded(last)
                    }
                    .buttonStyle(KopiPressStyle())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KopiTheme.accent)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

/// One card: content preview, meta row, selection ring, hover lift and quick-paste
/// shortcut. A click copies the card straight away and moves the selection to it; the
/// chevron expands it in place; dragging carries its content to other applications.
/// Everything that changes with the pointer is a colour, a border or one small shadow,
/// so scrolling stays cheap.
struct ClipboardCardView: View {
    let item: ClipboardItemSummary
    let position: Int
    @ObservedObject var model: PanelViewModel
    let previews: PreviewStore
    @ObservedObject private var preview: PreviewStore.Entry
    let commands: PanelCommands
    let isSelected: Bool
    let isExpanded: Bool
    @StateObject private var hover = PanelState(false)
    @StateObject private var detail = PanelState<ClipboardItemDetail?>(nil)
    @StateObject private var largeImage = PanelState<CGImage?>(nil)
    @StateObject private var code = PanelState<CodeHighlight?>(nil)
    @Environment(\.kopiCardHeight) private var baseCardHeight
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        item: ClipboardItemSummary,
        position: Int,
        model: PanelViewModel,
        previews: PreviewStore,
        commands: PanelCommands,
        isSelected: Bool,
        isExpanded: Bool
    ) {
        self.item = item
        self.position = position
        self.model = model
        self.previews = previews
        self.preview = previews.entry(for: item.id)
        self.commands = commands
        self.isSelected = isSelected
        self.isExpanded = isExpanded
    }

    private var isHovering: Bool { hover.value }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cardContent
            cornerControls
        }
        .onHover { hover.value = $0 }
        .contextMenu { menu }
        .task(id: "\(isExpanded)-\(item.fingerprint)") {
            await loadExpandedContent()
        }
    }

    /// A drag carries one item, so only a card with a single piece of content starts one.
    private var draggableCard: some View {
        Group {
            if CardDragMapping.isDraggable(item) {
                card
                    .contentShape(.dragPreview, shape)
                    .onDrag { CardDrag.provider(for: dragSource) }
            } else {
                card
            }
        }
    }

    /// The card's click, drag and accessibility actions. A collected card offers no pin
    /// action: the collection is kept for good already, so there is nothing left for
    /// pinning to protect it from.
    private var cardContent: some View {
        draggableCard
            .onTapGesture { copy() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction(.default) { copy() }
            .accessibilityAction(named: "Paste") { commands.paste(item.id) }
            .accessibilityAction(named: "Copy") { commands.copy(item.id) }
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") { toggleExpansion() }
            .accessibilityAction(named: "Edit") { Task { await model.beginEditing(item.id) } }
            .accessibilityAction(named: "Delete") { Task { await model.delete(item.id) } }
            .modifier(PinAccessibilityAction(item: item) { Task { await model.togglePin(item.id) } })
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: KopiTheme.cardCornerRadius, style: .continuous)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: cardHeight - KopiTheme.cardFooterHeight, alignment: .topLeading)
                .clipped()

            metaRow
                .padding(.horizontal, KopiTheme.cardPadding)
                .frame(height: KopiTheme.cardFooterHeight)
                .background(KopiTheme.insetSurface.opacity(0.42))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(KopiTheme.border(contrast: contrast).opacity(0.55))
                        .frame(height: 0.5)
                        .allowsHitTesting(false)
                }
        }
        .frame(
            height: cardHeight,
            alignment: .topLeading
        )
        .background {
            surface.overlay {
                LinearGradient(
                    colors: [KopiTheme.surfaceHighlight, .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .overlay { ring }
        .background { elevation }
        .contentShape(shape)
        .animation(nil, value: isSelected)
        .animation(KopiMotion.animation(KopiMotion.hover, reduceMotion: reduceMotion), value: isHovering)
    }

    private var cardHeight: CGFloat {
        isExpanded ? KopiTheme.expandedCardHeight : baseCardHeight
    }

    /// Text, links and files keep a padded media area; a thumbnail reaches the card's
    /// edge instead, which is why only image cards ask for no padding. An expanded card
    /// always keeps its content off the edge.
    @ViewBuilder
    private var content: some View {
        if isExpanded {
            CardExpandedBody(item: item, detail: detail.value, image: largeImage.value, code: code.value, previews: previews)
                .padding(.horizontal, KopiTheme.cardPadding)
                .padding(.top, KopiTheme.cardPadding)
        } else {
            CardPreviewBody(item: item, previews: previews)
                .padding(.horizontal, item.kind == .image ? 0 : KopiTheme.cardPadding)
                .padding(.top, item.kind == .image ? 0 : 32)
        }
    }

    private var surface: Color {
        if isSelected { return KopiTheme.selectedCardSurface }
        return isHovering ? KopiTheme.hoverCardSurface : KopiTheme.cardSurface
    }

    private var ring: some View {
        shape.strokeBorder(
            KopiTheme.cardBorder(isSelected: isSelected, isHovering: isHovering, contrast: contrast),
            lineWidth: isSelected ? 2 : 1
        ).transaction { $0.animation = nil }
    }

    /// The lift behind the card: a hover shadow, or the accent glow of the selection.
    /// It only exists while the card is lifted, so the scrolling path never carries a
    /// shadow per card.
    @ViewBuilder
    private var elevation: some View {
        if isSelected || isHovering {
            shape
                .fill(KopiTheme.cardSurface)
                .shadow(
                    color: isSelected
                        ? KopiTheme.Elevation.selectionColor(contrast: contrast)
                        : KopiTheme.Elevation.cardColor(contrast: contrast),
                    radius: isSelected ? KopiTheme.Elevation.selectionRadius : KopiTheme.Elevation.cardRadius,
                    y: isSelected ? KopiTheme.Elevation.selectionY : KopiTheme.Elevation.cardY
                )
                .transition(.opacity)
        }
    }

    /// The same always-visible maximise control as Notes, alongside quick paste.
    private var cornerControls: some View {
        HStack(spacing: 4) {
            expandButton
            cornerBadge
        }
        .padding(6)
        .animation(KopiMotion.animation(KopiMotion.hover, reduceMotion: reduceMotion), value: isHovering)
    }

    private var expandButton: some View {
        MaximiseCardButton(action: { toggleExpansion() }, isFocused: isSelected || isHovering)
    }

    @ViewBuilder
    private var cornerBadge: some View {
        if model.isBusy(item.id) {
            ProgressView()
                .controlSize(.mini)
                .padding(4)
                .background(Capsule().fill(KopiTheme.chipSurface))
                .accessibilityLabel("Saving")
        } else if position <= 9 {
            QuickPasteBadge(position: position, isProminent: isHovering || isSelected)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if color != nil {
                Label("Color", systemImage: "paintpalette")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                KindBadge(kind: item.kind)
            }
            if let highlight = preview.code, color == nil {
                CodeLanguageBadge(language: highlight.language)
            }
            if item.isEdited {
                Image(systemName: "pencil").kopiTooltip("Edited item")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            if let source = metaText {
                Text(source)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill").kopiTooltip("Pinned item")
                    .font(.system(size: 9))
                    .foregroundStyle(KopiTheme.accent)
                    .accessibilityHidden(true)
            }
            Text(CardTimestamp.description(for: item.lastCopiedAt))
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.secondary)
            CardActionsMenu { menu }
        }
        .font(.system(size: 9.5, weight: .medium))
        .lineLimit(1)
    }

    private var metaText: String? {
        if let label = item.label, !label.isEmpty { return label }
        if let source = item.sourceApp?.kopiDisplayName { return source }
        if item.kind == .files, item.fileCount > 1 { return "\(item.fileCount) items" }
        return nil
    }

    @ViewBuilder
    private var menu: some View {
        Button("Paste", systemImage: "doc.on.clipboard") { commands.paste(item.id) }
        Button("Maximise", systemImage: "arrow.up.left.and.arrow.down.right") { toggleExpansion() }
        Button("Copy", systemImage: "doc.on.doc") { commands.copy(item.id) }
        if let color {
            Button("Copy as HEX") { Task { await model.copyColorValue(color.hexString) } }
            Button("Copy as RGB") { Task { await model.copyColorValue(color.rgbString) } }
        }
        Button("Edit…", systemImage: "pencil") { Task { await model.beginEditing(item.id) } }
        if !item.isCollection {
            Button(item.isPinned ? "Unpin" : "Pin") { Task { await model.togglePin(item.id) } }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(item.id) } }
    }

    // MARK: - Actions

    private var color: ClipboardColor? {
        guard item.kind == .text || item.kind == .richText else { return nil }
        return ClipboardColor.parse(item.excerpt)
    }

    /// A click copies the card through the same path as ⌘C, moves the selection to it
    /// so Return pastes the card just copied, and leaves the panel open for the next one.
    private func copy() {
        model.selectForPaste(item.id)
        commands.copy(item.id)
    }

    private func toggleExpansion() {
        Task { await model.openPreview(item.id) }
    }

    private func loadExpandedContent() async {
        detail.value = nil
        largeImage.value = nil
        code.value = nil
        guard isExpanded else {
            detail.value = nil
            largeImage.value = nil
            code.value = nil
            return
        }
        if detail.value == nil {
            let loaded = await model.detail(for: item.id)
            guard !Task.isCancelled else { return }
            detail.value = loaded
        }
        if item.kind == .text, code.value == nil {
            let text = detail.value?.plainText ?? item.excerpt
            let loaded = await previews.codeHighlight(for: item, text: text)
            guard !Task.isCancelled else { return }
            code.value = loaded
        }
        if item.kind == .image, largeImage.value == nil {
            let loaded = await previews.largeImage(for: item)
            guard !Task.isCancelled else { return }
            largeImage.value = loaded
        }
    }

    private var dragSource: CardDragSource {
        model.dragSource(for: item)
    }

    private var accessibilityLabel: String {
        var parts: [String] = [item.kind.displayName, item.displayTitle]
        if let source = item.sourceApp?.kopiDisplayName {
            parts.append("from \(source)")
        }
        parts.append(CardTimestamp.description(for: item.lastCopiedAt))
        if item.isPinned { parts.append("pinned") }
        if item.isCollection { parts.append("collected") }
        if isExpanded { parts.append("expanded") }
        return parts.joined(separator: ", ")
    }
}

/// The pin action of a card, offered everywhere except on a collected card, which is
/// already kept for good.
private struct PinAccessibilityAction: ViewModifier {
    let item: ClipboardItemSummary
    let action: () -> Void

    func body(content: Content) -> some View {
        if item.isCollection {
            content
        } else {
            content.accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") { action() }
        }
    }
}
