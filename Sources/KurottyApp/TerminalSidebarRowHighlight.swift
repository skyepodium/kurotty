import AppKit

/// The one row-highlight painter shared by every left-sidebar list: command
/// history, agent sessions, and the file explorer.
///
/// The rule it enforces is that hover and selection must never be the same
/// paint at two opacities. Hover is achromatic, selection is chromatic and adds
/// two further cues — a leading accent rail and a heavier title — so a selected
/// row stays identifiable on both themes and for color-vision-deficient users.
/// Keyboard focus adds a fourth, separate cue: a ring around the highlight.
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
        var rail: NSColor?
        var focusRing: NSColor?
        var titleWeight: NSFont.Weight
        var titleColorRole: TitleColorRole

        static let rest = Appearance(
            fill: nil,
            rail: nil,
            focusRing: nil,
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
        static var railCornerRadiusPX: CGFloat { DesignTokens.Component.sidebarRowSelectionRailCornerRadiusPX }
        static var focusRingWidthPX: CGFloat { DesignTokens.Component.sidebarRowFocusRingWidthPX }
        static var focusRingOutsetPX: CGFloat { DesignTokens.Component.sidebarRowFocusRingOutsetPX }

        static func highlightRect(in bounds: NSRect) -> NSRect {
            bounds.insetBy(dx: insetXPX, dy: insetYPX)
        }

        /// Leading rail: full highlight height, pinned to the highlight inset.
        static func railRect(in bounds: NSRect) -> NSRect {
            let highlight = highlightRect(in: bounds)
            return NSRect(
                x: highlight.minX,
                y: highlight.minY,
                width: railWidthPX,
                height: highlight.height
            )
        }

        static func focusRingRect(in bounds: NSRect) -> NSRect {
            highlightRect(in: bounds).insetBy(dx: -focusRingOutsetPX, dy: -focusRingOutsetPX)
        }

        static var focusRingCornerRadiusPX: CGFloat { cornerRadiusPX + focusRingOutsetPX }
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
                    rail: nil,
                    focusRing: nil,
                    titleWeight: Typography.restTitleWeight,
                    titleColorRole: .primary
                )
            }
            return Appearance(
                fill: theme.pressFill,
                rail: nil,
                focusRing: nil,
                titleWeight: Typography.restTitleWeight,
                titleColorRole: .primary
            )
        }

        guard isActiveSelection else {
            return Appearance(
                fill: theme.textPrimary.withAlphaComponent(
                    DesignTokens.Component.sidebarRowInactiveSelectionAlphaRATIO
                ),
                rail: nil,
                focusRing: nil,
                titleWeight: Typography.restTitleWeight,
                titleColorRole: .secondary
            )
        }

        return Appearance(
            fill: state.isPressed ? theme.pressFill : theme.selectionFill,
            rail: theme.accent,
            focusRing: isFocusedSelection ? theme.focusRing : nil,
            titleWeight: Typography.selectedTitleWeight,
            titleColorRole: .primary
        )
    }

    /// Draws the resolved appearance into the current graphics context.
    static func paint(_ appearance: Appearance, in bounds: NSRect) {
        guard !bounds.isEmpty else {
            return
        }
        let highlightRect = Geometry.highlightRect(in: bounds)
        if let fill = appearance.fill {
            fill.setFill()
            NSBezierPath(
                roundedRect: highlightRect,
                xRadius: Geometry.cornerRadiusPX,
                yRadius: Geometry.cornerRadiusPX
            ).fill()
        }
        if let rail = appearance.rail {
            rail.setFill()
            NSBezierPath(
                roundedRect: Geometry.railRect(in: bounds),
                xRadius: Geometry.railCornerRadiusPX,
                yRadius: Geometry.railCornerRadiusPX
            ).fill()
        }
        if let focusRing = appearance.focusRing {
            focusRing.setStroke()
            let ringPath = NSBezierPath(
                roundedRect: Geometry.focusRingRect(in: bounds),
                xRadius: Geometry.focusRingCornerRadiusPX,
                yRadius: Geometry.focusRingCornerRadiusPX
            )
            ringPath.lineWidth = Geometry.focusRingWidthPX
            ringPath.stroke()
        }
    }

    /// Hover and selection must be instant. A fade makes a list feel laggy, so
    /// the row layers disable the implicit animations Core Animation would
    /// otherwise attach to these keys.
    enum LayerAnimation {
        static let disabledKeys = ["backgroundColor", "position", "bounds"]

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

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard !isSelected else {
            return
        }
        TerminalSidebarRowHighlight.paint(currentAppearance, in: bounds)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else {
            return
        }
        TerminalSidebarRowHighlight.paint(currentAppearance, in: bounds)
    }

    private var currentAppearance: TerminalSidebarRowHighlight.Appearance {
        TerminalSidebarRowHighlight.appearance(for: highlightState, theme: chromeTheme)
    }

    private func refreshHighlight() {
        needsDisplay = true
        let appearance = currentAppearance
        for subview in subviews {
            guard let styling = subview as? TerminalSidebarRowTitleStyling else {
                continue
            }
            styling.applySidebarRowTitleStyle(appearance)
        }
    }
}
