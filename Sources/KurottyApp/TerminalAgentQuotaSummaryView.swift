import AppKit

/// Rate-limit quota section, sitting directly above the daily spend strip in
/// the agent-session sidebar.
///
/// It is a sibling of `TerminalAgentUsageSummaryView` rather than a part of it,
/// because the two answer different questions and want opposite visual
/// grammars. The spend strip asks "how much did I burn, and is today normal" —
/// an unbounded magnitude, so it is a bar per day scaled against its own peak
/// with colour carrying size. Quota asks "how much of a fixed allowance is
/// gone" — a bounded ratio with a hard ceiling, which is a meter: a full-width
/// track, a fill, and a percentage. Folding a meter into a strip built around
/// relative heights would have made the ceiling invisible, which is the only
/// thing a quota reading is for.
///
/// Colour follows from that too. The spend strip's ramp is a single-hue
/// sequential scale for magnitude and is deliberately not a fault signal;
/// quota is the opposite, so the fill is recessive ink until the window is
/// nearly spent and then steps to the theme's own `warning` and `error` rungs —
/// the same rungs the status bar already uses for a hot CPU. It never borrows
/// from the usage ramp, which would say "big" where this has to say "close".
@MainActor
final class TerminalAgentQuotaSummaryView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let rowStackView = NSStackView()
    private var chromeTheme: DesignTokens.ChromeTheme = .dark
    private var summary = AgentRateLimitQuotaSummary.empty
    /// Captured once per update so every row in one render agrees on "now";
    /// re-reading the clock per row could round two reset labels differently.
    private var renderedAt = Date()
    /// Hiding an AppKit view does not retract its constraints, so a hidden
    /// section would still reserve the height of its header. The sidebar of a
    /// user whose only agent reports no quota must not carry a blank band, so
    /// the collapse is a constraint rather than just `isHidden`.
    private var collapsedHeightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func update(summary: AgentRateLimitQuotaSummary, now: Date = Date()) {
        self.summary = summary
        renderedAt = now
        // Hidden entirely when nobody reported a live window: a section of
        // nothing but "not reported" rows is an apology, not information.
        let isCollapsed = !summary.hasAnyReportedWindow
        isHidden = isCollapsed
        collapsedHeightConstraint?.isActive = isCollapsed
        rebuildRows()
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        DesignTokens.Typography.sectionHeader.apply(to: titleLabel, color: theme.textTertiary)
        rebuildRows()
    }

    private func configureSubviews() {
        titleLabel.stringValue = AppLocalization.string(.agentQuotaTitle)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        rowStackView.orientation = .vertical
        rowStackView.alignment = .leading
        rowStackView.spacing = DesignTokens.Component.AgentQuota.sectionRowGapPX
        rowStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStackView)

        let insetX = DesignTokens.Space.x4PX
        // The vertical chain sits one step below required so the collapse
        // constraint can win outright instead of logging a conflict; the
        // horizontal constraints stay required because they always hold.
        let verticalChain = [
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            rowStackView.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: DesignTokens.Space.x2PX
            ),
            rowStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        verticalChain.forEach { $0.priority = .defaultHigh }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate(verticalChain + [
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -insetX),
            rowStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            rowStackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
        ])
        let collapsed = heightAnchor.constraint(equalToConstant: 0)
        collapsedHeightConstraint = collapsed
        collapsed.isActive = true
        applyChromeTheme(chromeTheme)
    }

    /// Rows are rebuilt rather than reused: the number of windows an agent
    /// reports changes when a plan changes, and the section repaints only on an
    /// index refresh, which is already the rate the whole sidebar redraws at.
    private func rebuildRows() {
        rowStackView.arrangedSubviews.forEach { view in
            rowStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for entry in summary.entries {
            guard entry.isReported else {
                continue
            }
            for window in entry.windows {
                let row = AgentQuotaMeterRowView(frame: .zero)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.update(
                    agent: entry.agent,
                    window: window,
                    now: renderedAt,
                    theme: chromeTheme
                )
                rowStackView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowStackView.widthAnchor).isActive = true
            }
        }
        toolTip = AgentRateLimitQuotaCopy.summaryTooltip(for: summary, now: renderedAt)
    }
}

/// One window: `Codex 5h` on the left, the percentage right-aligned in a fixed
/// slot, and a full-width filled track underneath.
@MainActor
final class AgentQuotaMeterRowView: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let percentField = NSTextField(labelWithString: "")
    private let meterView = AgentQuotaMeterView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func update(
        agent: AgentSessionKind,
        window: AgentRateLimitWindow,
        now: Date,
        theme: DesignTokens.ChromeTheme
    ) {
        labelField.font = DesignTokens.Typography.rowSecondary.font
        // Monospaced digits: the number moves while a session runs and must not
        // shift the meter beside it.
        percentField.font = DesignTokens.Typography.statusBarNum.font
        labelField.textColor = theme.textSecondary
        let pressure = AgentRateLimitQuotaCopy.pressure(forFraction: window.usedFraction)
        percentField.textColor = Self.valueColor(for: pressure, theme: theme)

        let windowLabel = AgentRateLimitQuotaCopy.windowLabel(minutes: window.windowMinutes)
        // The reset is appended to the label rather than given a line of its
        // own: it is the second half of the same sentence, and a third line per
        // window would make the section taller than the list it sits above.
        let reset = AgentRateLimitQuotaCopy.resetLabel(for: window, now: now)
        labelField.stringValue = [
            "\(agent.shortLabel) \(windowLabel)",
            reset,
        ].compactMap { $0 }.joined(separator: " · ")
        percentField.stringValue = "\(AgentRateLimitQuotaCopy.percent(window.usedFraction))%"

        meterView.update(fraction: window.usedFraction, pressure: pressure, theme: theme)
        toolTip = AgentRateLimitQuotaCopy.rowSummary(agent: agent, window: window, now: now)
        setAccessibilityLabel(AgentRateLimitQuotaCopy.accessibilityLabel(agent: agent, window: window))
    }

    /// The same rungs the status bar's resource values use, so one amber means
    /// one thing across the whole chrome.
    static func valueColor(
        for pressure: AgentRateLimitQuotaCopy.Pressure,
        theme: DesignTokens.ChromeTheme
    ) -> NSColor {
        switch pressure {
        case .comfortable:
            return theme.textSecondary
        case .warning:
            return theme.warning
        case .exhausted:
            return theme.error
        }
    }

    private func configureSubviews() {
        labelField.lineBreakMode = .byTruncatingTail
        labelField.isSelectable = false
        percentField.alignment = .right
        percentField.isSelectable = false

        for view in [labelField, percentField, meterView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Setting content-hugging on the label lets the percentage keep its
        // reserved slot while the label absorbs the remaining width.
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.AgentQuota.rowHeightPX),

            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.topAnchor.constraint(equalTo: topAnchor),
            labelField.trailingAnchor.constraint(
                lessThanOrEqualTo: percentField.leadingAnchor,
                constant: -DesignTokens.Space.x2PX
            ),

            percentField.trailingAnchor.constraint(equalTo: trailingAnchor),
            percentField.firstBaselineAnchor.constraint(equalTo: labelField.firstBaselineAnchor),
            percentField.widthAnchor.constraint(
                equalToConstant: DesignTokens.Component.AgentQuota.percentWidthPX
            ),

            meterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            meterView.trailingAnchor.constraint(equalTo: trailingAnchor),
            meterView.topAnchor.constraint(
                equalTo: labelField.bottomAnchor,
                constant: DesignTokens.Component.AgentQuota.labelMeterGapPX
            ),
            meterView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.AgentQuota.meterTrackHeightPX
            ),
        ])
    }
}

/// A filled track. Layer-only so it never runs `draw(_:)` and never animates:
/// a quota meter that slides on every index refresh would pull the eye to a
/// number nobody asked to watch.
@MainActor
final class AgentQuotaMeterView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var fraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        for sublayer in [trackLayer, fillLayer] {
            ChromeMotion.disableImplicitAnimations(on: sublayer)
            sublayer.cornerRadius = DesignTokens.Component.AgentQuota.meterTrackCornerRadiusPX
            layer?.addSublayer(sublayer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func update(
        fraction: Double,
        pressure: AgentRateLimitQuotaCopy.Pressure,
        theme: DesignTokens.ChromeTheme
    ) {
        self.fraction = min(1, max(0, fraction))
        trackLayer.backgroundColor = theme.hairline
            .withAlphaComponent(DesignTokens.Component.AgentQuota.meterTrackAlphaRATIO)
            .cgColor
        fillLayer.backgroundColor = AgentQuotaMeterRowView.valueColor(
            for: pressure,
            theme: theme
        ).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        trackLayer.frame = bounds
        guard bounds.width > 0 else {
            fillLayer.frame = .zero
            return
        }
        let width = fraction <= 0
            ? 0
            : max(
                DesignTokens.Component.AgentQuota.meterMinimumFillWidthPX,
                bounds.width * CGFloat(fraction)
            )
        fillLayer.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}
