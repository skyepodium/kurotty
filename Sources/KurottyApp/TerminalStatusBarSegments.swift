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
    /// Every constant a segment or its subclasses take from a scaled token.
    /// Constraints are the one part of a segment a re-theme cannot refresh on
    /// its own, so they are registered here and replayed from
    /// `applyChromeTheme`.
    let metrics = ChromeMetricBindings()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure() {
        wantsLayer = true
        // The segment's hover/press wash must land with the pointer; only the
        // value text inside it is allowed to crossfade.
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.cornerRadius = DesignTokens.Component.StatusBar.segmentCornerRadiusPX
        layer?.backgroundColor = NSColor.clear.cgColor
        contentStackView.orientation = .horizontal
        contentStackView.alignment = .centerY
        contentStackView.spacing = 0
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStackView)
        let segmentHeight = metrics.bind(heightAnchor.constraint(equalToConstant: 0)) {
            DesignTokens.Component.StatusBar.heightPX
        }
        NSLayoutConstraint.activate([
            contentStackView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DesignTokens.Component.StatusBar.segmentPaddingXPX
            ),
            contentStackView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DesignTokens.Component.StatusBar.segmentPaddingXPX
            ),
            contentStackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            segmentHeight,
        ])
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        metrics.reapply()
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
            alpha = DesignTokens.Component.StatusBar.pressFillAlphaRATIO
        } else if isHovered {
            alpha = DesignTokens.Component.StatusBar.hoverFillAlphaRATIO
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
            width: DesignTokens.Component.StatusBar.dotSizePX,
            height: DesignTokens.Component.StatusBar.dotSizePX
        )
    }

    override func layout() {
        super.layout()
        let inset = DesignTokens.Component.StatusBar.hollowRingLineWidthPX / 2
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
            shapeLayer.lineWidth = DesignTokens.Component.StatusBar.hollowRingLineWidthPX
            shapeLayer.strokeColor = chromeTheme.textMuted
                .withAlphaComponent(DesignTokens.Component.StatusBar.hollowRingAlphaRATIO)
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
            return theme.accent
        case .waiting:
            return theme.warning
        case .error:
            return theme.error
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
        badgeContainer.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        badgeContainer.layer?.cornerRadius = DesignTokens.Component.StatusBar.badgeCornerRadiusPX

        glyphView.imageScaling = .scaleProportionallyDown

        applyChromeFonts()
        labelField.lineBreakMode = .byTruncatingTail
        labelField.isSelectable = false
        labelField.cell?.truncatesLastVisibleLine = true

        detailField.lineBreakMode = .byTruncatingTail
        detailField.isSelectable = false
        detailField.cell?.truncatesLastVisibleLine = true

        badgeField.isSelectable = false
        badgeField.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeField)

        contentStackView.addArrangedSubview(dotView)
        contentStackView.addArrangedSubview(glyphView)
        contentStackView.addArrangedSubview(spinnerView)
        contentStackView.addArrangedSubview(labelField)
        contentStackView.addArrangedSubview(badgeContainer)
        contentStackView.addArrangedSubview(detailField)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.dotGlyphGapPX, after: dotView)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.glyphLabelGapPX, after: glyphView)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.glyphLabelGapPX, after: spinnerView)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.labelDetailGapPX, after: labelField)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.labelDetailGapPX, after: badgeContainer)

        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: DesignTokens.Component.StatusBar.dotSizePX),
            dotView.heightAnchor.constraint(equalToConstant: DesignTokens.Component.StatusBar.dotSizePX),
            metrics.bind(glyphView.widthAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.StatusBar.iconPointSizePT
            },
            metrics.bind(glyphView.heightAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.StatusBar.iconPointSizePT
            },
            metrics.bind(spinnerView.widthAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.StatusBar.spinnerSizePX
            },
            metrics.bind(spinnerView.heightAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.StatusBar.spinnerSizePX
            },
            metrics.bind(labelField.widthAnchor.constraint(lessThanOrEqualToConstant: 0)) {
                DesignTokens.Component.StatusBar.agentLabelMaxWidthPX
            },
            metrics.bind(detailField.widthAnchor.constraint(lessThanOrEqualToConstant: 0)) {
                DesignTokens.Component.StatusBar.agentDetailMaxWidthPX
            },
            metrics.bind(badgeContainer.heightAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.StatusBar.badgeHeightPX
            },
            badgeField.leadingAnchor.constraint(
                equalTo: badgeContainer.leadingAnchor,
                constant: DesignTokens.Component.StatusBar.badgeTextInsetXPX
            ),
            badgeField.trailingAnchor.constraint(
                equalTo: badgeContainer.trailingAnchor,
                constant: -DesignTokens.Component.StatusBar.badgeTextInsetXPX
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
        applyChromeFonts()
        applyContent()
    }

    /// Re-read on every re-theme, not just at build: the ramp these come from
    /// moves with the UI text scale.
    private func applyChromeFonts() {
        labelField.font = DesignTokens.Typography.statusBar.font
        detailField.font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.Typography.statusBar.sizePT,
            weight: DesignTokens.Typography.statusBar.weight
        )
        badgeField.font = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.Component.StatusBar.badgeFontSizePT,
            weight: DesignTokens.Typography.badge.weight
        )
    }

    override func applyHoverState(isHovered: Bool) {
        labelField.textColor = isHovered ? chromeTheme.textPrimary : chromeTheme.textSecondary
        guard summary.isCallToAction else {
            return
        }
        labelField.attributedStringValue = Self.callToActionText(
            summary.label,
            color: isHovered ? chromeTheme.textPrimary : chromeTheme.textSecondary,
            font: labelField.font ?? NSFont.systemFont(ofSize: DesignTokens.Component.StatusBar.fontSizePT),
            isUnderlined: isHovered
        )
    }

    private func applyContent() {
        dotView.apply(style: summary.dot, theme: chromeTheme)
        spinnerView.applyChromeTheme(chromeTheme)
        let showsSpinner = summary.showsSpinner
        spinnerView.isHidden = !showsSpinner
        glyphView.isHidden = showsSpinner || !summary.showsAgentGlyph
        // Palette-tinted: the glyph is rebuilt on theme change rather than
        // retinted, because the color lives in the image.
        glyphView.image = Icon.symbol(
            IconSymbol.agent,
            pointSizePT: DesignTokens.Component.StatusBar.iconPointSizePT,
            weight: .medium,
            tint: chromeTheme.textMuted
        )
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
                font: labelField.font ?? DesignTokens.Typography.statusBar.font,
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
            .withAlphaComponent(DesignTokens.Component.StatusBar.hoverFillAlphaRATIO)
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

// MARK: - Quota segment

/// Leading group: a short meter, the agent/window name, and the percentage of
/// the fullest live rate-limit window.
///
/// The meter is here rather than only in the popover because the whole point of
/// the segment is peripheral vision: a number alone requires reading, a filled
/// track does not. It hides itself whole when no agent reports a quota, so a
/// Claude-only user never sees a permanently empty slot.
@MainActor
final class TerminalStatusBarQuotaSegmentView: TerminalStatusBarSegmentView {
    private let meterView = AgentQuotaMeterView(frame: .zero)
    private let labelField = NSTextField(labelWithString: "")
    private let percentField = NSTextField(labelWithString: "")
    private var summary = TerminalStatusBarQuotaSummary.absent
    private var visibility = TerminalStatusBarVisibility.full

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var currentSummary: TerminalStatusBarQuotaSummary {
        summary
    }

    private func configureContent() {
        applyChromeFonts()
        // Starts hidden. `update` short-circuits on an unchanged summary, and
        // the initial summary is `.absent`, so without this a fresh bar would
        // carry an empty hover target until an agent first reported.
        isHidden = true
        labelField.lineBreakMode = .byTruncatingTail
        labelField.isSelectable = false
        percentField.isSelectable = false
        percentField.alignment = .right

        meterView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.addArrangedSubview(meterView)
        contentStackView.addArrangedSubview(labelField)
        contentStackView.addArrangedSubview(percentField)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.iconValueGapPX, after: meterView)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.iconValueGapPX, after: labelField)

        NSLayoutConstraint.activate([
            meterView.widthAnchor.constraint(
                equalToConstant: DesignTokens.Component.AgentQuota.statusBarMeterWidthPX
            ),
            meterView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.AgentQuota.meterTrackHeightPX
            ),
            metrics.bind(percentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)) {
                DesignTokens.Component.StatusBar.cpuValueMinWidthPX
            },
        ])
    }

    func update(summary: TerminalStatusBarQuotaSummary, visibility: TerminalStatusBarVisibility) {
        guard summary != self.summary || visibility != self.visibility else {
            return
        }
        self.summary = summary
        self.visibility = visibility
        applyContent()
    }

    override func applyThemeToContent() {
        applyChromeFonts()
        applyContent()
    }

    /// Re-read on every re-theme, not just at build: the ramp these come from
    /// moves with the UI text scale.
    private func applyChromeFonts() {
        labelField.font = DesignTokens.Typography.statusBar.font
        percentField.font = DesignTokens.Typography.statusBarNum.font
    }

    override func applyHoverState(isHovered: Bool) {
        labelField.textColor = isHovered ? chromeTheme.textSecondary : chromeTheme.textMuted
    }

    private func applyContent() {
        isHidden = !summary.isPresent || !visibility.showsQuota
        guard summary.isPresent else {
            toolTip = nil
            return
        }
        labelField.stringValue = summary.label
        labelField.textColor = chromeTheme.textMuted
        percentField.stringValue = summary.percentText
        percentField.textColor = Self.valueColor(for: summary.severity, theme: chromeTheme)
        meterView.update(
            fraction: summary.usedFraction,
            pressure: Self.pressure(for: summary.severity),
            theme: chromeTheme
        )
        toolTip = summary.tooltip.isEmpty ? nil : summary.tooltip
        setAccessibilityLabel(summary.tooltip)
    }

    private static func valueColor(
        for severity: TerminalStatusBarSeverity,
        theme: DesignTokens.ChromeTheme
    ) -> NSColor {
        switch severity {
        case .normal:
            return theme.textMuted
        case .warning:
            return theme.warning
        case .error:
            return theme.error
        }
    }

    private static func pressure(
        for severity: TerminalStatusBarSeverity
    ) -> AgentRateLimitQuotaCopy.Pressure {
        switch severity {
        case .normal:
            return .comfortable
        case .warning:
            return .warning
        case .error:
            return .exhausted
        }
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
        for iconView in [memoryIconView, cpuIconView] {
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyDown
        }

        applyChromeFonts()
        for valueField in [memoryValueField, cpuValueField] {
            valueField.alignment = .right
            valueField.isSelectable = false
            valueField.wantsLayer = true
        }

        contentStackView.addArrangedSubview(memoryIconView)
        contentStackView.addArrangedSubview(memoryValueField)
        contentStackView.addArrangedSubview(cpuIconView)
        contentStackView.addArrangedSubview(cpuValueField)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.iconValueGapPX, after: memoryIconView)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.metricGapPX, after: memoryValueField)
        contentStackView.setCustomSpacing(DesignTokens.Component.StatusBar.iconValueGapPX, after: cpuIconView)

        NSLayoutConstraint.activate([
            metrics.bind(memoryIconView.widthAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.StatusBar.iconPointSizePT
            },
            metrics.bind(memoryIconView.heightAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.StatusBar.iconPointSizePT
            },
            metrics.bind(cpuIconView.widthAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.StatusBar.iconPointSizePT
            },
            metrics.bind(cpuIconView.heightAnchor.constraint(equalToConstant: 0)) {
                DesignTokens.Component.StatusBar.iconPointSizePT
            },
            // Reserved widths: the digits change every two seconds and must not
            // move anything around them.
            metrics.bind(memoryValueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)) {
                DesignTokens.Component.StatusBar.memoryValueMinWidthPX
            },
            metrics.bind(cpuValueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)) {
                DesignTokens.Component.StatusBar.cpuValueMinWidthPX
            },
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
        applyChromeFonts()
        applyContent(animatesValues: false)
    }

    /// Re-read on every re-theme, not just at build: the ramp these come from
    /// moves with the UI text scale.
    private func applyChromeFonts() {
        for valueField in [memoryValueField, cpuValueField] {
            valueField.font = DesignTokens.Typography.statusBarNum.font
        }
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
        for (iconView, symbolName) in [
            (memoryIconView, IconSymbol.memory),
            (cpuIconView, IconSymbol.cpu),
        ] {
            iconView.image = Icon.symbol(
                symbolName,
                pointSizePT: DesignTokens.Component.StatusBar.iconPointSizePT,
                weight: .medium,
                tint: chromeTheme.textMuted
            )
        }

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
            transition.duration = DesignTokens.Motion.seconds(fromMS: DesignTokens.Motion.statusValueCrossfadeDurationMS)
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
            field.textColor = chromeTheme.warning
        case .error:
            field.textColor = chromeTheme.error
        }
    }
}
