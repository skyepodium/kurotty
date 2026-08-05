import AppKit

/// Token usage strip above the agent-session list.
///
/// The headline is a number, not a plot: "how much did I burn today" is a
/// single value, and a chart of one number is a decoration. The plot underneath
/// answers a different question — whether today is normal — so it is a bar per
/// day over a trailing window, one series, no legend, and no axes: the strip is
/// read against its own peak, and the exact values are on the bars' tooltips.
///
/// Only the current day is accent-colored. Every other bar is recessive ink, so
/// the accent still means "this one" the way it does everywhere else in the
/// chrome rather than becoming a series color.
final class TerminalAgentUsageSummaryView: NSView {
    private enum Layout {
        static let barCornerRadiusPX: CGFloat = 1.5
        static let barGapPX: CGFloat = 2
        static let stripHeightPX: CGFloat = 28
        static let minimumBarHeightPX: CGFloat = 2
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")
    private let breakdownLabel = NSTextField(labelWithString: "")
    private let stripView = DayStripView()
    private var chromeTheme: DesignTokens.ChromeTheme = .dark

    private var summary: AgentTokenUsageSummary = .empty

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func update(summary: AgentTokenUsageSummary) {
        self.summary = summary
        stripView.update(summary: summary, theme: chromeTheme)
        applyText()
        isHidden = summary.window.isEmpty
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        titleLabel.textColor = theme.textTertiary
        totalLabel.textColor = theme.textPrimary
        breakdownLabel.textColor = theme.textTertiary
        stripView.update(summary: summary, theme: theme)
    }

    private func configureSubviews() {
        titleLabel.font = DesignTokens.Typography.sectionHeader.font
        titleLabel.stringValue = AppLocalization.string(.agentUsageToday)
        // Monospaced digits: the number changes while the session runs and the
        // label beside it must not shift when a digit gets wider.
        totalLabel.font = DesignTokens.Typography.statusBarNum.font
        breakdownLabel.font = DesignTokens.Typography.rowSecondary.font
        breakdownLabel.lineBreakMode = .byTruncatingTail

        for label in [titleLabel, totalLabel, breakdownLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        stripView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stripView)

        let insetX = DesignTokens.Space.x4PX
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.firstBaselineAnchor.constraint(equalTo: totalLabel.firstBaselineAnchor),

            totalLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
            totalLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: DesignTokens.Space.x3PX
            ),
            totalLabel.topAnchor.constraint(equalTo: topAnchor),

            stripView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            stripView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
            stripView.topAnchor.constraint(
                equalTo: totalLabel.bottomAnchor,
                constant: DesignTokens.Space.x2PX
            ),
            stripView.heightAnchor.constraint(equalToConstant: Layout.stripHeightPX),

            breakdownLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            breakdownLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
            breakdownLabel.topAnchor.constraint(
                equalTo: stripView.bottomAnchor,
                constant: DesignTokens.Space.x2PX
            ),
            breakdownLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyChromeTheme(chromeTheme)
    }

    private func applyText() {
        totalLabel.stringValue = AgentTokenUsageFormatter.compact(summary.today.totalTokens)
        breakdownLabel.stringValue = AgentSessionUsageCopy.breakdown(for: summary)
        setAccessibilityLabel(AgentSessionUsageCopy.accessibilityLabel(for: summary))
        toolTip = AgentSessionUsageCopy.breakdown(for: summary)
    }

    /// One bar per day, oldest on the left, scaled against the window's own
    /// peak. Bars are drawn rather than composed from subviews because the
    /// strip repaints on every index refresh.
    private final class DayStripView: NSView {
        private var summary: AgentTokenUsageSummary = .empty
        private var theme: DesignTokens.ChromeTheme = .dark

        override var isFlipped: Bool { true }

        func update(summary: AgentTokenUsageSummary, theme: DesignTokens.ChromeTheme) {
            self.summary = summary
            self.theme = theme
            removeAllToolTips()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let days = summary.days
            guard !days.isEmpty, bounds.width > 0 else { return }
            let peak = max(summary.peakDayTokens, 1)
            let slot = bounds.width / CGFloat(days.count)
            let barWidth = max(1, slot - Layout.barGapPX)

            for (index, day) in days.enumerated() {
                let ratio = CGFloat(day.totalTokens) / CGFloat(peak)
                let height = day.totalTokens == 0
                    ? Layout.minimumBarHeightPX
                    : max(Layout.minimumBarHeightPX, bounds.height * ratio)
                let rect = NSRect(
                    x: CGFloat(index) * slot,
                    y: bounds.height - height,
                    width: barWidth,
                    height: height
                )
                let isToday = index == days.count - 1
                let color = if day.totalTokens == 0 {
                    theme.hairline
                } else if isToday {
                    theme.accent
                } else {
                    theme.textTertiary.withAlphaComponent(0.55)
                }
                color.setFill()
                NSBezierPath(
                    roundedRect: rect,
                    xRadius: Layout.barCornerRadiusPX,
                    yRadius: Layout.barCornerRadiusPX
                ).fill()
                addToolTip(
                    rect,
                    owner: AgentSessionUsageCopy.dayTooltip(for: day) as NSString,
                    userData: nil
                )
            }
        }
    }
}

/// Copy for the usage strip, split out so the wording is testable without
/// building an AppKit view.
enum AgentSessionUsageCopy {
    static func breakdown(for summary: AgentTokenUsageSummary) -> String {
        let usage = summary.window
        let parts = [
            "\(AppLocalization.string(.agentUsageInput)) \(AgentTokenUsageFormatter.compact(usage.inputTokens))",
            "\(AppLocalization.string(.agentUsageOutput)) \(AgentTokenUsageFormatter.compact(usage.outputTokens))",
            "\(AppLocalization.string(.agentUsageCache)) \(AgentTokenUsageFormatter.compact(usage.cacheReadTokens + usage.cacheWriteTokens))",
        ]
        return parts.joined(separator: " · ")
    }

    static func dayTooltip(for day: AgentTokenUsageSummary.Day) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLocalization.language.rawValue)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(formatter.string(from: day.date)) · \(AgentTokenUsageFormatter.compact(day.totalTokens))"
    }

    static func accessibilityLabel(for summary: AgentTokenUsageSummary) -> String {
        AppLocalization.format(
            .agentUsageAccessibility,
            AgentTokenUsageFormatter.compact(summary.today.totalTokens),
            summary.sessionCount
        )
    }
}
