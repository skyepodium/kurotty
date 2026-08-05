import AppKit

/// Segment cells for `TerminalStatusBarView`: the shared hover/press click
/// target, the agent segment on the left, and the resource segment on the
/// right. Split out of the bar so each file stays small and the bar itself only
/// owns layout, data sources, and the popover/alert flows.

// MARK: - Shared click target

/// A full-height, hover-highlighted click target with horizontal padding.
///
/// Rendering contract: hover and press states are layer background changes
/// only. The cursor stays `.arrow` — this is chrome, not a hyperlink.
@MainActor
class TerminalStatusBarSegmentView: NSView {
    var onClick: (() -> Void)?

    let contentStackView = NSStackView()
    private(set) var chromeTheme = DesignTokens.ChromeTheme.dark
    private var isHovered = false
    private var isPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = TerminalStatusBarTokens.segmentCornerRadiusPX
        layer?.backgroundColor = NSColor.clear.cgColor
        contentStackView.orientation = .horizontal
        contentStackView.alignment = .centerY
        contentStackView.spacing = 0
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStackView)
        NSLayoutConstraint.activate([
            contentStackView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: TerminalStatusBarTokens.segmentPaddingXPX
            ),
            contentStackView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -TerminalStatusBarTokens.segmentPaddingXPX
            ),
            contentStackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: TerminalStatusBarTokens.heightPX),
        ])
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        updateBackground()
        applyThemeToContent()
    }

    /// Overridden by subclasses to recolor their own labels and icons.
    func applyThemeToContent() {}

    /// Overridden by subclasses that change label color on hover.
    func applyHoverState(isHovered: Bool) {}

    override func resetCursorRects() {
        // Chrome affordance, not a link: keep the arrow cursor.
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
        applyHoverState(isHovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateBackground()
        applyHoverState(isHovered: false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateBackground()
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        updateBackground()
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onClick?()
    }

    private func updateBackground() {
        let alpha: CGFloat
        if isPressed {
            alpha = TerminalStatusBarTokens.pressFillAlphaRATIO
        } else if isHovered {
            alpha = TerminalStatusBarTokens.hoverFillAlphaRATIO
        } else {
            alpha = 0
        }
        layer?.backgroundColor = chromeTheme.textPrimary.withAlphaComponent(alpha).cgColor
    }
}

// MARK: - Status dot

/// Filled dot, hollow ring, or nothing. Layer-only so it never runs `draw(_:)`.
@MainActor
final class TerminalStatusBarDotView: NSView {
    private let shapeLayer = CAShapeLayer()
    private var style = TerminalStatusBarDotStyle.none
    private var chromeTheme = DesignTokens.ChromeTheme.dark

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shapeLayer.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull()]
        layer?.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: TerminalStatusBarTokens.dotSizePX,
            height: TerminalStatusBarTokens.dotSizePX
        )
    }

    override func layout() {
        super.layout()
        let inset = TerminalStatusBarTokens.hollowRingLineWidthPX / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        shapeLayer.frame = bounds
        shapeLayer.path = CGPath(ellipseIn: rect, transform: nil)
    }

    func apply(style: TerminalStatusBarDotStyle, theme: DesignTokens.ChromeTheme) {
        self.style = style
        chromeTheme = theme
        applyAppearance()
    }

    private func applyAppearance() {
        switch style {
        case .none:
            isHidden = true
        case .hollowRing:
            isHidden = false
            shapeLayer.fillColor = NSColor.clear.cgColor
            shapeLayer.lineWidth = TerminalStatusBarTokens.hollowRingLineWidthPX
            shapeLayer.strokeColor = chromeTheme.textMuted
                .withAlphaComponent(TerminalStatusBarTokens.hollowRingAlphaRATIO)
                .cgColor
        case let .filled(role):
            isHidden = false
            shapeLayer.lineWidth = 0
            shapeLayer.strokeColor = nil
            shapeLayer.fillColor = Self.color(for: role, theme: chromeTheme).cgColor
        }
    }

    static func color(for role: TerminalStatusBarDotRole, theme: DesignTokens.ChromeTheme) -> NSColor {
        switch role {
        case .idle:
            return theme.activeStatusDot
        case .working:
            return DesignTokens.Color.accentBlue
        case .waiting:
            return DesignTokens.Color.warningOrange
        case .error:
            return DesignTokens.Color.errorRed
        }
    }
}

// MARK: - Agent segment

/// Left segment: status dot, agent glyph or spinner, label, optional detail,
/// and a count badge when more than one agent is reporting.
@MainActor
final class TerminalStatusBarAgentSegmentView: TerminalStatusBarSegmentView {
    private let dotView = TerminalStatusBarDotView(frame: .zero)
    private let glyphView = NSImageView()
    private let spinnerView = AgentActivityIndicatorView(frame: .zero)
    private let labelField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let detailField = NSTextField(labelWithString: "")
    private var summary = TerminalStatusBarAgentSummary(
        dot: .none,
        label: "",
        detail: nil,
        showsSpinner: false,
        showsAgentGlyph: false,
        agentCount: 0,
        isCallToAction: false,
        action: .offerToEnableStatusHooks,
        tooltip: ""
    )
    private var visibility = TerminalStatusBarVisibility.full

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var currentSummary: TerminalStatusBarAgentSummary {
        summary
    }

    private func configureContent() {
        dotView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        spinnerView.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = TerminalStatusBarTokens.badgeCornerRadiusPX

        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.image = NSImage(
            systemSymbolName: TerminalStatusBarSymbols.agent,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: TerminalStatusBarTokens.iconPointSizePT,
                weight: .medium
            )
        )

        labelField.font = NSFont.systemFont(ofSize: TerminalStatusBarTokens.fontSizePT, weight: .regular)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.isSelectable = false
        labelField.cell?.truncatesLastVisibleLine = true

        detailField.font = NSFont.monospacedDigitSystemFont(
            ofSize: TerminalStatusBarTokens.fontSizePT,
            weight: .regular
        )
        detailField.lineBreakMode = .byTruncatingTail
        detailField.isSelectable = false
        detailField.cell?.truncatesLastVisibleLine = true

        badgeField.font = NSFont.monospacedDigitSystemFont(
            ofSize: TerminalStatusBarTokens.badgeFontSizePT,
            weight: .medium
        )
        badgeField.isSelectable = false
        badgeField.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeField)

        contentStackView.addArrangedSubview(dotView)
        contentStackView.addArrangedSubview(glyphView)
        contentStackView.addArrangedSubview(spinnerView)
        contentStackView.addArrangedSubview(labelField)
        contentStackView.addArrangedSubview(badgeContainer)
        contentStackView.addArrangedSubview(detailField)
        contentStackView.setCustomSpacing(TerminalStatusBarTokens.dotGlyphGapPX, after: dotView)
        contentStackView.setCustomSpacing(TerminalStatusBarTokens.glyphLabelGapPX, after: glyphView)
        contentStackView.setCustomSpacing(TerminalStatusBarTokens.glyphLabelGapPX, after: spinnerView)
        contentStackView.setCustomSpacing(TerminalStatusBarTokens.labelDetailGapPX, after: labelField)
        contentStackView.setCustomSpacing(TerminalStatusBarTokens.labelDetailGapPX, after: badgeContainer)

        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: TerminalStatusBarTokens.dotSizePX),
            dotView.heightAnchor.constraint(equalToConstant: TerminalStatusBarTokens.dotSizePX),
            glyphView.widthAnchor.constraint(equalToConstant: TerminalStatusBarTokens.iconPointSizePT),
            glyphView.heightAnchor.constraint(equalToConstant: TerminalStatusBarTokens.iconPointSizePT),
            spinnerView.widthAnchor.constraint(equalToConstant: TerminalStatusBarTokens.spinnerSizePX),
            spinnerView.heightAnchor.constraint(equalToConstant: TerminalStatusBarTokens.spinnerSizePX),
            labelField.widthAnchor.constraint(
                lessThanOrEqualToConstant: TerminalStatusBarTokens.agentLabelMaxWidthPX
            ),
            detailField.widthAnchor.constraint(
                lessThanOrEqualToConstant: TerminalStatusBarTokens.agentDetailMaxWidthPX
            ),
            badgeContainer.heightAnchor.constraint(equalToConstant: TerminalStatusBarTokens.badgeHeightPX),
            badgeField.leadingAnchor.constraint(
                equalTo: badgeContainer.leadingAnchor,
                constant: TerminalStatusBarTokens.badgeTextInsetXPX
            ),
            badgeField.trailingAnchor.constraint(
                equalTo: badgeContainer.trailingAnchor,
                constant: -TerminalStatusBarTokens.badgeTextInsetXPX
            ),
            badgeField.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
        ])
    }

    func update(summary: TerminalStatusBarAgentSummary, visibility: TerminalStatusBarVisibility) {
        // Guard the whole update: the bar sits under a surface that repaints
        // while typing, and an unchanged status must not touch layout.
        guard summary != self.summary || visibility != self.visibility else {
            return
        }
        self.summary = summary
        self.visibility = visibility
        applyContent()
    }

    override func applyThemeToContent() {
        applyContent()
    }

    override func applyHoverState(isHovered: Bool) {
        labelField.textColor = isHovered ? chromeTheme.textPrimary : chromeTheme.textSecondary
        guard summary.isCallToAction else {
            return
        }
        labelField.attributedStringValue = Self.callToActionText(
            summary.label,
            color: isHovered ? chromeTheme.textPrimary : chromeTheme.textSecondary,
            font: labelField.font ?? NSFont.systemFont(ofSize: TerminalStatusBarTokens.fontSizePT),
            isUnderlined: isHovered
        )
    }

    private func applyContent() {
        dotView.apply(style: summary.dot, theme: chromeTheme)
        let showsSpinner = summary.showsSpinner
        spinnerView.isHidden = !showsSpinner
        glyphView.isHidden = showsSpinner || !summary.showsAgentGlyph
        glyphView.contentTintColor = chromeTheme.textMuted
        if showsSpinner {
            spinnerView.update(status: AgentActivityStatus(state: .working))
        } else {
            spinnerView.update(status: nil)
        }

        labelField.isHidden = !visibility.showsAgentLabel || summary.label.isEmpty
        labelField.textColor = chromeTheme.textSecondary
        if summary.isCallToAction {
            labelField.attributedStringValue = Self.callToActionText(
                summary.label,
                color: chromeTheme.textSecondary,
                font: labelField.font ?? NSFont.systemFont(ofSize: TerminalStatusBarTokens.fontSizePT),
                isUnderlined: false
            )
        } else {
            labelField.stringValue = summary.label
        }

        let detail = summary.detail
        detailField.isHidden = !visibility.showsAgentDetail || detail == nil
        detailField.stringValue = detail ?? ""
        detailField.textColor = chromeTheme.textMuted

        let showsBadge = summary.agentCount > 1
        badgeContainer.isHidden = !showsBadge
        badgeField.stringValue = showsBadge ? "\(summary.agentCount)" : ""
        badgeField.textColor = chromeTheme.textMuted
        badgeContainer.layer?.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(TerminalStatusBarTokens.hoverFillAlphaRATIO)
            .cgColor

        // Anything truncation removed still has to be reachable.
        toolTip = summary.tooltip.isEmpty ? nil : summary.tooltip
    }

    private static func callToActionText(
        _ text: String,
        color: NSColor,
        font: NSFont,
        isUnderlined: Bool
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if isUnderlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

// MARK: - Resource segment

/// Right segment: memory and CPU with reserved monospaced-digit widths so a
/// changing number never reflows the bar.
@MainActor
final class TerminalStatusBarResourceSegmentView: TerminalStatusBarSegmentView {
    private let memoryIconView = NSImageView()
    private let memoryValueField = NSTextField(labelWithString: "")
    private let cpuIconView = NSImageView()
    private let cpuValueField = NSTextField(labelWithString: "")
    private var usage = TerminalWindowResourceUsage.empty
    private var visibility = TerminalStatusBarVisibility.full
    private var totalPhysicalBytes = ProcessInfo.processInfo.physicalMemory

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureContent() {
        for (iconView, symbolName) in [
            (memoryIconView, TerminalStatusBarSymbols.memory),
            (cpuIconView, TerminalStatusBarSymbols.cpu),
        ] {
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyDown
            iconView.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: TerminalStatusBarTokens.iconPointSizePT,
                    weight: .medium
                )
            )
        }

        for valueField in [memoryValueField, cpuValueField] {
            valueField.font = NSFont.monospacedDigitSystemFont(
                ofSize: TerminalStatusBarTokens.fontSizePT,
                weight: .medium
            )
            valueField.alignment = .right
            valueField.isSelectable = false
            valueField.wantsLayer = true
        }

        contentStackView.addArrangedSubview(memoryIconView)
        contentStackView.addArrangedSubview(memoryValueField)
        contentStackView.addArrangedSubview(cpuIconView)
        contentStackView.addArrangedSubview(cpuValueField)
        contentStackView.setCustomSpacing(TerminalStatusBarTokens.iconValueGapPX, after: memoryIconView)
        contentStackView.setCustomSpacing(TerminalStatusBarTokens.metricGapPX, after: memoryValueField)
        contentStackView.setCustomSpacing(TerminalStatusBarTokens.iconValueGapPX, after: cpuIconView)

        NSLayoutConstraint.activate([
            memoryIconView.widthAnchor.constraint(equalToConstant: TerminalStatusBarTokens.iconPointSizePT),
            memoryIconView.heightAnchor.constraint(equalToConstant: TerminalStatusBarTokens.iconPointSizePT),
            cpuIconView.widthAnchor.constraint(equalToConstant: TerminalStatusBarTokens.iconPointSizePT),
            cpuIconView.heightAnchor.constraint(equalToConstant: TerminalStatusBarTokens.iconPointSizePT),
            // Reserved widths: the digits change every two seconds and must not
            // move anything around them.
            memoryValueField.widthAnchor.constraint(
                greaterThanOrEqualToConstant: TerminalStatusBarTokens.memoryValueMinWidthPX
            ),
            cpuValueField.widthAnchor.constraint(
                greaterThanOrEqualToConstant: TerminalStatusBarTokens.cpuValueMinWidthPX
            ),
        ])
    }

    func update(usage: TerminalWindowResourceUsage, visibility: TerminalStatusBarVisibility) {
        guard usage != self.usage || visibility != self.visibility else {
            return
        }
        let didValuesChange = usage != self.usage
        self.usage = usage
        self.visibility = visibility
        applyContent(animatesValues: didValuesChange)
    }

    override func applyThemeToContent() {
        applyContent(animatesValues: false)
    }

    override func applyHoverState(isHovered: Bool) {
        let color = isHovered ? chromeTheme.textSecondary : chromeTheme.textMuted
        applyValueColor(color, to: memoryValueField, severity: memorySeverity)
        applyValueColor(color, to: cpuValueField, severity: TerminalResourceUsageFormatter.severity(
            cpuPercent: usage.cpuPercent
        ))
    }

    private var memorySeverity: TerminalStatusBarSeverity {
        TerminalResourceUsageFormatter.severity(
            residentBytes: usage.residentBytes,
            totalPhysicalBytes: totalPhysicalBytes
        )
    }

    private func applyContent(animatesValues: Bool) {
        memoryIconView.contentTintColor = chromeTheme.textMuted
        cpuIconView.contentTintColor = chromeTheme.textMuted

        let memoryText = TerminalResourceUsageFormatter.memoryText(bytes: usage.residentBytes)
        let cpuText = TerminalResourceUsageFormatter.cpuText(percent: usage.cpuPercent)
        setValue(memoryText, on: memoryValueField, animated: animatesValues)
        setValue(cpuText, on: cpuValueField, animated: animatesValues)
        applyValueColor(chromeTheme.textMuted, to: memoryValueField, severity: memorySeverity)
        applyValueColor(
            chromeTheme.textMuted,
            to: cpuValueField,
            severity: TerminalResourceUsageFormatter.severity(cpuPercent: usage.cpuPercent)
        )

        memoryValueField.isHidden = !visibility.showsMemoryValue
        cpuIconView.isHidden = !visibility.showsCPUMetric
        cpuValueField.isHidden = !visibility.showsCPUMetric
        toolTip = TerminalResourceUsageFormatter.summaryText(
            bytes: usage.residentBytes,
            cpuPercent: usage.cpuPercent
        ) + "\n" + TerminalResourceUsageFormatter.memoryDescription
    }

    private func setValue(_ text: String, on field: NSTextField, animated: Bool) {
        guard field.stringValue != text else {
            return
        }
        // Crossfade the whole value; a counter roll would draw attention to
        // routine telemetry and animate a label the user is not looking at.
        if animated, let layer = field.layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = TerminalStatusBarTokens.valueCrossfadeSeconds
            layer.add(transition, forKey: nil)
        }
        field.stringValue = text
    }

    private func applyValueColor(
        _ baseColor: NSColor,
        to field: NSTextField,
        severity: TerminalStatusBarSeverity
    ) {
        switch severity {
        case .normal:
            field.textColor = baseColor
        case .warning:
            field.textColor = DesignTokens.Color.warningOrange
        case .error:
            field.textColor = DesignTokens.Color.errorRed
        }
    }
}
