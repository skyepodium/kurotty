import AppKit

/// The one row-highlight painter shared by every left-sidebar list: command
/// history, agent sessions, and the file explorer.
///
/// The rule it enforces is that hover and selection must never be the same
/// paint at two opacities. Hover is a translucent achromatic wash over the
/// panel; selection is an *opaque raised surface* lifted off it, and adds two
/// further cues — a leading accent rail and a heavier title — so a selected row
/// stays identifiable on both themes and for color-vision-deficient users.
/// Keyboard focus adds a fourth, separate cue: a ring around the highlight.
///
/// Selection used to be a translucent accent wash, which cost two things. The
/// accent rail was accent-on-accent and effectively invisible, so the three
/// "independent" cues were two; and the row's text sat on a colour nothing had
/// measured, which is why `DesignTokenColorRampTests` had to declare selected
/// rows out of scope. An opaque `surfaceRaised` pill is a surface the ramp
/// already owns and already guarantees, so the text on a selected row is now
/// covered by the same contrast floors as text anywhere else.
///
/// State resolution is a pure function (`appearance(for:theme:)`) so it can be
/// tested without a window, a table view, or a first responder.
enum TerminalSidebarRowHighlight {
    /// Everything the painter needs to know about a row. Derived by the row
    /// view from AppKit state; never read back out of the drawing code.
    struct State: Equatable {
        var isSelected: Bool
        var isHovered: Bool
        var isPressed: Bool
        /// The row's window is key. A background window must not paint accent.
        var isWindowActive: Bool
        /// The row's list is the first responder, i.e. arrow keys move here.
        var isListFocused: Bool

        init(
            isSelected: Bool = false,
            isHovered: Bool = false,
            isPressed: Bool = false,
            isWindowActive: Bool = false,
            isListFocused: Bool = false
        ) {
            self.isSelected = isSelected
            self.isHovered = isHovered
            self.isPressed = isPressed
            self.isWindowActive = isWindowActive
            self.isListFocused = isListFocused
        }

        static let rest = State()
    }

    /// Which text rank the row title should use. Selection in a background
    /// window demotes the title so the row still reads as "not the focus".
    enum TitleColorRole: Equatable {
        case primary
        case secondary
    }

    /// The resolved paint for one row. `nil` means "draw nothing for this cue".
    struct Appearance: Equatable {
        var fill: NSColor?
        /// Hairline around the pill.
        ///
        /// Not decoration: on the dark ramp `surfaceRaised` sits only ten
        /// levels above the panel it is drawn on, which is *less* separation
        /// than the hover wash carries, so fill alone left a selected row
        /// reading quieter than a hovered one. A border is how the search pill
        /// already makes the same surface read as an object on the same
        /// background.
        var border: NSColor?
        var rail: NSColor?
        var focusRing: NSColor?
        /// Drop shadow under the highlight. Only an active selection carries
        /// one: it is the cue that says the pill is a surface rather than a
        /// tint, and a hovered or pressed row is not a surface.
        var shadow: DesignTokens.Elevation.Shadow?
        var titleWeight: NSFont.Weight
        var titleColorRole: TitleColorRole

        static let rest = Appearance(
            fill: nil,
            border: nil,
            rail: nil,
            focusRing: nil,
            shadow: nil,
            titleWeight: Typography.restTitleWeight,
            titleColorRole: .primary
        )
    }

    /// Title weights are expressed for a `.regular` baseline. Rows whose base
    /// weight is heavier step up the ladder instead (see `titleWeight(base:)`).
    enum Typography {
        static let restTitleWeight: NSFont.Weight = .regular
        static let selectedTitleWeight: NSFont.Weight = .medium
        private static let weightLadder: [NSFont.Weight] = [
            .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black
        ]

        /// One step heavier than `base`, saturating at the top of the ladder.
        /// A `.regular` title becomes `.medium`, matching the spec value.
        static func emphasized(_ base: NSFont.Weight) -> NSFont.Weight {
            guard let index = weightLadder.firstIndex(of: base) else {
                return selectedTitleWeight
            }
            return weightLadder[min(index + 1, weightLadder.count - 1)]
        }
    }

    enum Geometry {
        static var insetXPX: CGFloat { DesignTokens.Component.sidebarRowHighlightInsetXPX }
        static var insetYPX: CGFloat { DesignTokens.Component.sidebarRowHighlightInsetYPX }
        static var cornerRadiusPX: CGFloat { DesignTokens.Component.sidebarRowHighlightCornerRadiusPX }
        static var railWidthPX: CGFloat { DesignTokens.Component.sidebarRowSelectionRailWidthPX }
        static var borderWidthPX: CGFloat { DesignTokens.Component.sidebarRowSelectionBorderWidthPX }
        static var railCornerRadiusPX: CGFloat { DesignTokens.Component.sidebarRowSelectionRailCornerRadiusPX }
        static var focusRingWidthPX: CGFloat { DesignTokens.Component.sidebarRowFocusRingWidthPX }
        static var focusRingOutsetPX: CGFloat { DesignTokens.Component.sidebarRowFocusRingOutsetPX }

        /// - Parameter topInsetPX: dead space at the top of the row that the
        ///   highlight must not cover. Section-header rows reserve air above
        ///   their content; painting over it would turn the gap between groups
        ///   back into a tall row.
        static func highlightRect(in bounds: NSRect, topInsetPX: CGFloat = 0) -> NSRect {
            let inset = bounds.insetBy(dx: insetXPX, dy: insetYPX)
            guard topInsetPX > 0 else {
                return inset
            }
            // AppKit row views are unflipped, so "top" is the high-y edge.
            return NSRect(
                x: inset.minX,
                y: inset.minY,
                width: inset.width,
                height: max(inset.height - topInsetPX, 0)
            )
        }

        /// Leading rail: full highlight height, pinned to the highlight inset.
        static func railRect(in bounds: NSRect, topInsetPX: CGFloat = 0) -> NSRect {
            let highlight = highlightRect(in: bounds, topInsetPX: topInsetPX)
            return NSRect(
                x: highlight.minX,
                y: highlight.minY,
                width: railWidthPX,
                height: highlight.height
            )
        }

        static func focusRingRect(in bounds: NSRect, topInsetPX: CGFloat = 0) -> NSRect {
            highlightRect(in: bounds, topInsetPX: topInsetPX)
                .insetBy(dx: -focusRingOutsetPX, dy: -focusRingOutsetPX)
        }

        static var focusRingCornerRadiusPX: CGFloat { cornerRadiusPX + focusRingOutsetPX }

        /// The pill's outline, for the layer shadow that seats it.
        static func highlightPath(in bounds: NSRect, topInsetPX: CGFloat = 0) -> CGPath {
            CGPath(
                roundedRect: highlightRect(in: bounds, topInsetPX: topInsetPX),
                cornerWidth: cornerRadiusPX,
                cornerHeight: cornerRadiusPX,
                transform: nil
            )
        }
    }

    /// Pure state resolution. No AppKit drawing, no view state.
    @MainActor
    static func appearance(
        for state: State,
        theme: DesignTokens.ChromeTheme
    ) -> Appearance {
        // Focus only exists inside a key window; a background list is inactive
        // no matter what its first responder says.
        let isActiveSelection = state.isSelected && state.isWindowActive
        let isFocusedSelection = isActiveSelection && state.isListFocused

        guard state.isSelected else {
            guard state.isPressed else {
                guard state.isHovered else {
                    return .rest
                }
                return Appearance(
                    fill: theme.hoverFill,
                    border: nil,
                    rail: nil,
                    focusRing: nil,
                    shadow: nil,
                    titleWeight: Typography.restTitleWeight,
                    titleColorRole: .primary
                )
            }
            return Appearance(
                fill: theme.pressFill,
                border: nil,
                rail: nil,
                focusRing: nil,
                shadow: nil,
                titleWeight: Typography.restTitleWeight,
                titleColorRole: .primary
            )
        }

        // A background window's selection is still a selection, so it keeps the
        // raised surface: at `surfaceSidebar` it measured about 1.03:1 against
        // the panel and simply could not be found again. What it gives up is
        // everything that says "acting on this right now" — the accent rail, the
        // elevation, and the title weight.
        guard isActiveSelection else {
            return Appearance(
                fill: theme.surfaceRaised,
                border: theme.hairline,
                rail: nil,
                focusRing: nil,
                shadow: nil,
                titleWeight: Typography.restTitleWeight,
                titleColorRole: .secondary
            )
        }

        // Press takes the elevation away rather than repainting the pill: the
        // gesture is pushing the row down, and swapping the surface for a wash
        // would make a click look like the row lost its selection.
        return Appearance(
            fill: theme.surfaceRaised,
            border: theme.borderStrong,
            rail: theme.accent,
            focusRing: isFocusedSelection ? theme.focusRing : nil,
            shadow: state.isPressed ? nil : DesignTokens.Elevation.sidebarSelectedRow(for: theme),
            titleWeight: Typography.selectedTitleWeight,
            titleColorRole: .primary
        )
    }

    /// Draws the resolved appearance into the current graphics context.
    ///
    /// The shadow is deliberately not drawn here. A layer-backed row renders
    /// `draw(_:)` into a backing store the size of its own bounds, so a shadow
    /// painted through Core Graphics would be sheared off at the row edge — a
    /// hard line, which is worse than no shadow. `TerminalSidebarRowView` hangs
    /// it off the layer's `shadowPath` instead, which is not bounds-clipped.
    static func paint(_ appearance: Appearance, in bounds: NSRect, topInsetPX: CGFloat = 0) {
        guard !bounds.isEmpty else {
            return
        }
        let highlightRect = Geometry.highlightRect(in: bounds, topInsetPX: topInsetPX)
        if let fill = appearance.fill {
            fill.setFill()
            NSBezierPath(
                roundedRect: highlightRect,
                xRadius: Geometry.cornerRadiusPX,
                yRadius: Geometry.cornerRadiusPX
            ).fill()
        }
        if let border = appearance.border {
            border.setStroke()
            // Stroked on the inside of the pill: a centred stroke would put
            // half a hairline outside the highlight rect, and the rail drawn
            // after it would then sit a half point in from the pill's edge.
            let borderPath = NSBezierPath(
                roundedRect: highlightRect.insetBy(
                    dx: Geometry.borderWidthPX / 2,
                    dy: Geometry.borderWidthPX / 2
                ),
                xRadius: Geometry.cornerRadiusPX - Geometry.borderWidthPX / 2,
                yRadius: Geometry.cornerRadiusPX - Geometry.borderWidthPX / 2
            )
            borderPath.lineWidth = Geometry.borderWidthPX
            borderPath.stroke()
        }
        if let rail = appearance.rail {
            rail.setFill()
            NSBezierPath(
                roundedRect: Geometry.railRect(in: bounds, topInsetPX: topInsetPX),
                xRadius: Geometry.railCornerRadiusPX,
                yRadius: Geometry.railCornerRadiusPX
            ).fill()
        }
        if let focusRing = appearance.focusRing {
            focusRing.setStroke()
            let ringPath = NSBezierPath(
                roundedRect: Geometry.focusRingRect(in: bounds, topInsetPX: topInsetPX),
                xRadius: Geometry.focusRingCornerRadiusPX,
                yRadius: Geometry.focusRingCornerRadiusPX
            )
            ringPath.lineWidth = Geometry.focusRingWidthPX
            ringPath.stroke()
        }
    }

    /// Hover and selection must be instant. A fade makes a list feel laggy, so
    /// the row layers disable the implicit animations Core Animation would
    /// otherwise attach to these keys. The shadow keys are here for the same
    /// reason: an elevated selection that fades in trails the arrow key that
    /// moved it.
    enum LayerAnimation {
        static let disabledKeys = [
            "backgroundColor",
            "position",
            "bounds",
            "shadowColor",
            "shadowOffset",
            "shadowOpacity",
            "shadowPath",
            "shadowRadius",
        ]

        static var disabledActions: [String: CAAction] {
            var actions: [String: CAAction] = [:]
            for key in disabledKeys {
                actions[key] = NSNull()
            }
            return actions
        }

        static func disableImplicitAnimations(on layer: CALayer?) {
            guard let layer else {
                return
            }
            layer.actions = disabledActions
        }
    }
}

/// Shared row geometry for every sidebar cell.
///
/// One rule, applied everywhere: the leading glyph occupies a reserved column,
/// never its own intrinsic width. SF Symbols are not a monospaced set — at 13pt
/// `folder` is 19pt wide and `doc` is 15pt — so a tree drawn to each glyph's
/// natural width has a filename column that moves depending on what kind of
/// thing each row happens to be. The git column already solved this for the
/// trailing marks; this is the same fix at the other end of the row.
@MainActor
enum TerminalSidebarRowLayout {
    /// Pins a glyph into the reserved leading column. The image view *is* the
    /// column: it takes the slot's width and centres whatever glyph it holds,
    /// so the label after it starts at the same x on every row.
    static func leadingSlotConstraints(
        glyphView: NSImageView,
        in cell: NSView,
        leadingInsetPX: CGFloat = 0,
        slotWidthPX: CGFloat = DesignTokens.Component.sidebarRowIconSlotWidthPX
    ) -> [NSLayoutConstraint] {
        glyphView.imageScaling = .scaleNone
        glyphView.imageAlignment = .alignCenter
        return [
            glyphView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leadingInsetPX),
            glyphView.widthAnchor.constraint(equalToConstant: slotWidthPX),
        ]
    }
}

/// The one place that decides whether a key event is "jump to the filter
/// field". Both sidebar outlines route it and the search pill advertises it, so
/// the binding and the badge cannot drift apart.
enum TerminalSidebarFilterKey {
    static func matches(_ event: NSEvent) -> Bool {
        // Modified `/` belongs to whoever bound it (⌘/ is a comment toggle in
        // most editors); only the bare key is a navigation shortcut.
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            return false
        }
        return event.charactersIgnoringModifiers?.first
            == DesignTokens.Component.sidebarSearchHintKeyCharacter
    }
}

/// Implemented by sidebar cell views so the shared row view can apply the
/// title-weight and title-color cues without knowing the cell's layout.
@MainActor
protocol TerminalSidebarRowTitleStyling: AnyObject {
    func applySidebarRowTitleStyle(_ appearance: TerminalSidebarRowHighlight.Appearance)
}

/// Applies the title cues (weight, text rank) of a resolved row appearance to a
/// cell's title label.
///
/// The cell names a type ramp role, never a weight: the role owns size, weight,
/// and font design, and the styler only expresses the *delta* selection
/// introduces. A cell may give selection its own text rank (`selectedColor`)
/// because several sidebar rows sit at `textSecondary` at rest and step up to
/// `textPrimary` only when they are the selected row.
@MainActor
struct TerminalSidebarRowTitleStyler {
    let role: DesignTokens.Typography.Role
    /// Rest and hover color.
    let restColor: NSColor
    /// Color once the row is the selected row of a key window.
    let selectedColor: NSColor
    let chromeTheme: DesignTokens.ChromeTheme

    init(
        role: DesignTokens.Typography.Role,
        restColor: NSColor,
        selectedColor: NSColor? = nil,
        chromeTheme: DesignTokens.ChromeTheme
    ) {
        self.role = role
        self.restColor = restColor
        self.selectedColor = selectedColor ?? restColor
        self.chromeTheme = chromeTheme
    }

    func apply(_ appearance: TerminalSidebarRowHighlight.Appearance, to label: NSTextField) {
        label.font = font(for: resolvedWeight(for: appearance))
        label.textColor = color(for: appearance)
    }

    func color(for appearance: TerminalSidebarRowHighlight.Appearance) -> NSColor {
        guard appearance.titleColorRole != .secondary else {
            return chromeTheme.textSecondary
        }
        // An accent rail is the marker of an active selection; rest and hover
        // never carry one.
        return appearance.rail == nil ? restColor : selectedColor
    }

    /// `.regular` titles land exactly on the spec's `.medium`; heavier base
    /// weights step up the ladder so the cue is visible everywhere.
    func resolvedWeight(for appearance: TerminalSidebarRowHighlight.Appearance) -> NSFont.Weight {
        guard appearance.titleWeight == TerminalSidebarRowHighlight.Typography.selectedTitleWeight else {
            return role.weight
        }
        return TerminalSidebarRowHighlight.Typography.emphasized(role.weight)
    }

    private func font(for weight: NSFont.Weight) -> NSFont {
        switch role.design {
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: role.sizePT, weight: weight)
        case .monospacedDigit:
            return NSFont.monospacedDigitSystemFont(ofSize: role.sizePT, weight: weight)
        case .system:
            return NSFont.systemFont(ofSize: role.sizePT, weight: weight)
        }
    }
}

/// Base row view implementing the three-state (plus focus and press) row
/// system. `TerminalCommandHistorySidebarRowView` and
/// `TerminalFileExplorerSidebarRowView` are thin subclasses so both lists paint
/// identically by construction.
@MainActor
class TerminalSidebarRowView: NSTableRowView {
    var chromeTheme: DesignTokens.ChromeTheme = .dark {
        didSet { refreshHighlight() }
    }

    /// Dead space at the top of the row that no highlight may cover. Set by the
    /// list delegate on section-header rows so the air above a group reads as a
    /// gap between groups rather than as a taller hover target.
    var highlightTopInsetPX: CGFloat = 0 {
        didSet { refreshHighlight() }
    }

    private var isMouseInside = false
    private var isPressed = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayerForInstantHighlight()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isSelected: Bool {
        didSet { refreshHighlight() }
    }

    override var isEmphasized: Bool {
        get { super.isEmphasized }
        set {
            super.isEmphasized = newValue
            refreshHighlight()
        }
    }

    /// Row state as AppKit currently reports it.
    var highlightState: TerminalSidebarRowHighlight.State {
        let isWindowActive = window?.isKeyWindow ?? false
        return TerminalSidebarRowHighlight.State(
            isSelected: isSelected,
            isHovered: isMouseInside,
            isPressed: isPressed,
            isWindowActive: isWindowActive,
            isListFocused: isWindowActive && isEmphasized
        )
    }

    private func configureLayerForInstantHighlight() {
        wantsLayer = true
        // The selection shadow lives outside the pill, which is outside the row
        // gutter; a clipping row layer would cut it into a hard edge.
        layer?.masksToBounds = false
        TerminalSidebarRowHighlight.LayerAnimation.disableImplicitAnimations(on: layer)
    }

    override func makeBackingLayer() -> CALayer {
        let backingLayer = super.makeBackingLayer()
        TerminalSidebarRowHighlight.LayerAnimation.disableImplicitAnimations(on: backingLayer)
        return backingLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureLayerForInstantHighlight()
        refreshHighlight()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard let styling = subview as? TerminalSidebarRowTitleStyling else {
            return
        }
        styling.applySidebarRowTitleStyle(currentAppearance)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        refreshHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        isPressed = false
        refreshHighlight()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        refreshHighlight()
        // The table view runs its own tracking loop; control returns here after
        // mouse-up, which is exactly the press duration.
        super.mouseDown(with: event)
        isPressed = false
        refreshHighlight()
    }

    override func layout() {
        super.layout()
        // The shadow is a path, so a row that changed width keeps the old
        // outline until it is rebuilt here.
        applySelectionShadow(currentAppearance)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard !isSelected else {
            return
        }
        TerminalSidebarRowHighlight.paint(
            currentAppearance,
            in: bounds,
            topInsetPX: highlightTopInsetPX
        )
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else {
            return
        }
        TerminalSidebarRowHighlight.paint(
            currentAppearance,
            in: bounds,
            topInsetPX: highlightTopInsetPX
        )
    }

    private var currentAppearance: TerminalSidebarRowHighlight.Appearance {
        TerminalSidebarRowHighlight.appearance(for: highlightState, theme: chromeTheme)
    }

    /// Hangs the pill's drop shadow off the row's own layer.
    ///
    /// `shadowPath` is independent of the layer's contents, so the shadow is
    /// not clipped to the row the way anything drawn in `draw(_:)` would be.
    /// That is the whole reason it lives here instead of in the painter.
    private func applySelectionShadow(_ appearance: TerminalSidebarRowHighlight.Appearance) {
        guard let layer else {
            return
        }
        layer.masksToBounds = false
        guard let shadow = appearance.shadow, !bounds.isEmpty else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
            return
        }
        shadow.apply(to: layer)
        layer.shadowPath = TerminalSidebarRowHighlight.Geometry.highlightPath(
            in: bounds,
            topInsetPX: highlightTopInsetPX
        )
    }

    private func refreshHighlight() {
        needsDisplay = true
        let appearance = currentAppearance
        applySelectionShadow(appearance)
        for subview in subviews {
            guard let styling = subview as? TerminalSidebarRowTitleStyling else {
                continue
            }
            styling.applySidebarRowTitleStyle(appearance)
        }
    }
}
