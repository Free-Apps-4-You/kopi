import AppKit
import SwiftUI
import KopiCore

/// Paint the complete panel in SwiftUI's render tree. A live NSVisualEffectView
/// inside the scaled transition host can leave differently composited rectangles
/// when hover invalidates only part of the hosting view after the reveal.
struct PanelSurface: View {
    var body: some View {
        KopiTheme.surface
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Outline of the panel: the rounded body, plus the neck that reaches a notched
/// display's top edge. The union of the two is what the surface, its border and the
/// content are clipped to, so the panel meets the camera housing without a gap.
struct PanelOutline: InsettableShape {
    var cornerRadius: CGFloat
    var attachment: PanelAttachment?
    private var inset: CGFloat = 0

    init(cornerRadius: CGFloat, attachment: PanelAttachment?) {
        self.cornerRadius = cornerRadius
        self.attachment = attachment
    }

    func path(in rect: CGRect) -> Path {
        let neckHeight = attachment?.neckHeight ?? 0
        let bounds = rect.insetBy(dx: inset, dy: inset)
        let bodyRect = CGRect(
            x: bounds.minX,
            y: bounds.minY + neckHeight,
            width: bounds.width,
            height: max(0, bounds.height - neckHeight)
        )
        let body = RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous).path(in: bodyRect)
        guard let attachment, neckHeight > 0 else { return body }
        let width = attachment.neckWidth - inset * 2
        guard width > 0 else { return body }
        let neck = CGRect(
            x: rect.midX + attachment.neckOffset - width / 2,
            y: rect.minY + inset,
            width: width,
            height: bodyRect.minY - rect.minY + 1
        )
        return Path(body.cgPath.union(CGPath(rect: neck, transform: nil)))
    }

    func inset(by amount: CGFloat) -> PanelOutline {
        var outline = self
        outline.inset += amount
        return outline
    }
}

/// Dimmed backdrop of the previews and editors: a material dim over the panel itself,
/// or a plain dim when translucency is switched off.
struct OverlayBackdrop: View {
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        KopiTheme.scrim.opacity(dimOpacity)
        .clipShape(RoundedRectangle(cornerRadius: KopiTheme.panelCornerRadius, style: .continuous))
        .padding(KopiTheme.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    private var dimOpacity: Double {
        if reduceTransparency { return contrast == .increased ? 0.50 : 0.35 }
        return contrast == .increased ? 0.24 : 0.10
    }

}

/// Rounded graphite surface shared by the previews, editors and the composer, so every
/// overlay sits on the same material, border and shadow.
struct OverlaySurface<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(KopiTheme.overlayPadding)
            .background(
                RoundedRectangle(cornerRadius: KopiTheme.overlayCornerRadius, style: .continuous)
                    .fill(KopiTheme.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: KopiTheme.overlayCornerRadius, style: .continuous)
                            .fill(LinearGradient(colors: [KopiTheme.surfaceHighlight, .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            )
            .overlay(
                RoundedRectangle(cornerRadius: KopiTheme.overlayCornerRadius, style: .continuous)
                    .strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(
                color: KopiTheme.Elevation.overlayColor,
                radius: KopiTheme.Elevation.overlayRadius,
                y: KopiTheme.Elevation.overlayY
            )
    }
}

/// One placeholder card, laid out like a real one so the grid does not jump when the
/// cards arrive. Its pulse is a single opacity on the blocks: nothing moves, nothing
/// blurs, and nothing animates once the cards are there.
struct SkeletonCard: View {
    @Environment(\.kopiCardHeight) private var cardHeight
    var pulse: Double = 0
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            block(height: 9).frame(width: 46)
            Spacer(minLength: 0)
            block(height: 8)
            block(height: 8).padding(.trailing, 56)
            Spacer(minLength: 0)
            block(height: 8).frame(width: 74)
        }
        .padding(KopiTheme.cardPadding)
        .frame(height: cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: KopiTheme.cardCornerRadius, style: .continuous)
                .fill(KopiTheme.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KopiTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1)
        )
        .opacity(blockOpacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var blockOpacity: Double { 0.55 + 0.45 * (1 - pulse) }

    private func block(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(KopiTheme.skeletonSurface(contrast: contrast))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }
}

/// Skeleton of the clipboard grid, in the columns the real cards will use.
struct SkeletonCardGrid: View {
    let columns: [GridItem]
    var cardCount: Int = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pulse = PanelState(false)

    var body: some View {
        LazyVGrid(columns: columns, spacing: KopiTheme.cardSpacing) {
            ForEach(0..<cardCount, id: \.self) { _ in
                SkeletonCard(pulse: pulse.value ? 1 : 0)
            }
        }
        .padding(.horizontal, KopiTheme.contentPadding)
        .padding(.top, 4)
        .onAppear {
            guard !reduceMotion else { return }
            pulse.set(true, animation: KopiMotion.skeletonPulse)
        }
    }
}

/// Skeleton of a list of note cards.
struct SkeletonNoteList: View {
    var rowCount: Int = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pulse = PanelState(false)

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<rowCount, id: \.self) { _ in
                SkeletonNoteRow(pulse: pulse.value ? 1 : 0)
            }
        }
        .padding(.horizontal, KopiTheme.contentPadding)
        .onAppear {
            guard !reduceMotion else { return }
            pulse.set(true, animation: KopiMotion.skeletonPulse)
        }
    }
}

/// One placeholder note card.
struct SkeletonNoteRow: View {
    var pulse: Double = 0
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            block(height: 9).frame(width: 160)
            block(height: 8)
            block(height: 8).padding(.trailing, 90)
            block(height: 8).frame(width: 110)
        }
        .padding(KopiTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: KopiTheme.cardCornerRadius, style: .continuous)
                .fill(KopiTheme.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KopiTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(KopiTheme.border(contrast: contrast), lineWidth: 1)
        )
        .opacity(0.55 + 0.45 * (1 - pulse))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func block(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(KopiTheme.skeletonSurface(contrast: contrast))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }
}
