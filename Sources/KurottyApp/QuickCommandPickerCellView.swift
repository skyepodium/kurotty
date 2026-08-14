import AppKit

/// One row of a picker.
///
/// **The selection is a shape inside the row, not a bar across it.** That one
/// decision is most of what separates a list that looks designed from a list
/// that looks like a table view, and it is why the pill is inset on every side
/// rather than drawn to the row's edges.
///
/// Four things travel across a row and each has one job:
///
/// - a glyph, in a fixed column so every title starts at the same x — a ragged
///   left edge is what makes a list read as a dump
/// - the title, which is what was searched for
/// - the detail, quiet, read only when the title was not enough
/// - a badge, given a shape as well as a colour, because state that is only a
///   colour is state some people cannot see
///
/// A secondary row is dimmed rather than hidden. The person asked for a
/// container in a pod, and the mesh proxy *is* in the pod; what it must not do
/// is look like the answer.
@MainActor
final class QuickCommandPickerCellView: NSTableCellView {
    private let selectionLayer = CALayer()
    private let glyphLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeBackground = NSView()
    private let returnHint = NSTextField(labelWithString: "↩")
    private let theme: DesignTokens.ChromeTheme

    private enum Metrics {
        /// Corner radius of the selection pill. The large step, because the
        /// pill is the one shape in the window doing any speaking.
        static var selectionRadiusPX: CGFloat { DesignTokens.Radius.lgPX }
        static var badgeRadiusPX: CGFloat { DesignTokens.Radius.smPX }
        static var badgeHorizontalPadPX: CGFloat { DesignTokens.Space.x2PX }
        /// How far the row's content sits inside the pill, so text never
        /// touches the fill's edge.
        static var contentPadPX: CGFloat { DesignTokens.Space.x4PX }
        /// Opacity of a row that is present but not the answer.
        static let secondaryALPHA: CGFloat = 0.55
    }

    init(theme: DesignTokens.ChromeTheme) {
        self.theme = theme
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows a row, and says whether it is the one under the cursor.
    func apply(_ row: QuickCommandPickerRow, isSelected: Bool) {
        glyphLabel.stringValue = row.glyph.map(String.init) ?? ""
        titleLabel.stringValue = row.title
        detailLabel.stringValue = row.detail

        badgeLabel.stringValue = row.badge ?? ""
        badgeBackground.isHidden = row.badge == nil

        // Only the recommended row carries the Return mark, and only while it
        // is selected — a hint pointing at a key that would do something else
        // is worse than no hint.
        returnHint.isHidden = !(row.isRecommended && isSelected)

        alphaValue = row.isSecondary ? Metrics.secondaryALPHA : 1
        selectionLayer.backgroundColor = isSelected ? theme.selectionFill.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = row.isSecondary ? theme.textSecondary : theme.textPrimary
    }

    override func layout() {
        super.layout()
        // Framed rather than constrained: the pill is one rectangle inset from
        // the row on every side, and a constraint graph for one rectangle is
        // ceremony.
        let inset = DesignTokens.Component.quickPickerSelectionInsetPX
        selectionLayer.frame = bounds.insetBy(dx: inset, dy: inset / 2)
        selectionLayer.cornerRadius = Metrics.selectionRadiusPX
    }

    private func configure() {
        wantsLayer = true
        layer?.addSublayer(selectionLayer)
        selectionLayer.zPosition = -1
        ChromeMotion.disableImplicitAnimations(on: selectionLayer)

        glyphLabel.alignment = .center
        glyphLabel.font = DesignTokens.Typography.rowTitle.font

        titleLabel.font = DesignTokens.Typography.rowTitleSel.font
        titleLabel.lineBreakMode = .byTruncatingTail

        // Monospaced, because the detail is machine text: an image tag, a
        // container id, a namespace. Proportional type makes `postgres:16` and
        // `postgres:l6` look alike, and those are the two the eye has to tell
        // apart at a glance.
        detailLabel.font = DesignTokens.Typography.monoBody.font
        detailLabel.textColor = theme.textTertiary
        detailLabel.lineBreakMode = .byTruncatingMiddle

        badgeLabel.font = DesignTokens.Typography.badge.font
        badgeLabel.textColor = theme.textSecondary
        badgeBackground.wantsLayer = true
        badgeBackground.layer?.cornerRadius = Metrics.badgeRadiusPX
        badgeBackground.layer?.backgroundColor = theme.hoverFill.cgColor

        returnHint.font = DesignTokens.Typography.badge.font
        returnHint.textColor = theme.textTertiary

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = DesignTokens.Space.x1PX / 2

        for view in [glyphLabel, text, badgeBackground, badgeLabel, returnHint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Metrics.contentPadPX
            ),
            glyphLabel.widthAnchor.constraint(
                equalToConstant: DesignTokens.Component.quickPickerGlyphColumnPX
            ),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            text.leadingAnchor.constraint(
                equalTo: glyphLabel.trailingAnchor,
                constant: DesignTokens.Space.x2PX
            ),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(
                lessThanOrEqualTo: badgeBackground.leadingAnchor,
                constant: -DesignTokens.Space.x2PX
            ),

            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeBackground.centerYAnchor.constraint(equalTo: badgeLabel.centerYAnchor),
            badgeBackground.centerXAnchor.constraint(equalTo: badgeLabel.centerXAnchor),
            badgeBackground.widthAnchor.constraint(
                equalTo: badgeLabel.widthAnchor,
                constant: Metrics.badgeHorizontalPadPX * 2
            ),
            badgeBackground.heightAnchor.constraint(
                equalTo: badgeLabel.heightAnchor,
                constant: DesignTokens.Space.x1PX
            ),

            badgeLabel.trailingAnchor.constraint(
                equalTo: returnHint.leadingAnchor,
                constant: -DesignTokens.Space.x3PX
            ),
            returnHint.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Metrics.contentPadPX
            ),
            returnHint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
