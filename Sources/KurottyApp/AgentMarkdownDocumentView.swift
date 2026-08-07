import AppKit

/// A rendered Markdown message: headings, prose, lists, quotes, rules, code
/// blocks and tables.
///
/// This view *is* the transcript row's container rather than a child of one, so
/// a message of plain prose costs exactly the two views it cost before this
/// renderer existed — this view and one text field. Every extra view is bought
/// by a construct that genuinely needs one.
@MainActor
final class AgentMarkdownDocumentView: NSView {
    private var segmentViews: [NSView] = []

    /// - Parameters:
    ///   - insetX: horizontal row inset, applied here so no wrapper view is
    ///     needed between this and the table row.
    ///   - insetY: vertical row inset, zero when nested inside a quote or list
    ///     item that already supplies its own.
    init(
        blocks: [AgentMarkdownBlock],
        theme: DesignTokens.ChromeTheme,
        insetX: CGFloat,
        insetY: CGFloat
    ) {
        super.init(frame: .zero)
        build(
            segments: AgentMarkdownSegmentPlanner.segments(for: blocks),
            theme: theme,
            insetX: insetX,
            insetY: insetY
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build(
        segments: [AgentMarkdownSegment],
        theme: DesignTokens.ChromeTheme,
        insetX: CGFloat,
        insetY: CGFloat
    ) {
        var constraints: [NSLayoutConstraint] = []
        var previous: NSView?
        for segment in segments {
            let view = makeSegmentView(segment, theme: theme)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            segmentViews.append(view)
            constraints.append(view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX))
            constraints.append(view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX))
            if let previous {
                constraints.append(view.topAnchor.constraint(
                    equalTo: previous.bottomAnchor,
                    constant: DesignTokens.Component.agentTranscriptBlockSpacingPX
                ))
            } else {
                constraints.append(view.topAnchor.constraint(equalTo: topAnchor, constant: insetY))
            }
            previous = view
        }
        if let previous {
            constraints.append(previous.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insetY))
        } else {
            // An empty document still has to have a height, or the row it sits
            // in resolves to an ambiguous one.
            constraints.append(heightAnchor.constraint(equalToConstant: insetY * 2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func makeSegmentView(
        _ segment: AgentMarkdownSegment,
        theme: DesignTokens.ChromeTheme
    ) -> NSView {
        switch segment {
        case let .flow(blocks):
            return Self.makeFlowView(blocks: blocks, theme: theme)
        case let .code(language, code):
            return AgentMarkdownCodeBlockView(language: language, code: code, theme: theme)
        case let .table(table):
            return AgentMarkdownTableView(table: table, theme: theme)
        case .rule:
            return AgentMarkdownRuleView(theme: theme)
        case let .nested(container, blocks):
            return AgentMarkdownNestedView(container: container, blocks: blocks, theme: theme)
        }
    }

    private static func makeFlowView(
        blocks: [AgentMarkdownBlock],
        theme: DesignTokens.ChromeTheme
    ) -> NSTextField {
        // Built as a wrapping label and then given attributed text: a label
        // created from an attributed string does not wrap, and a transcript
        // pane is resized constantly.
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = AgentMarkdownFlowComposer.attributedString(
            blocks: blocks,
            theme: theme
        )
        label.isSelectable = true
        // Links are styled by the composer; this is what makes them clickable.
        label.allowsEditingTextAttributes = true
        return label
    }

    // MARK: - Testing

    /// The views one message resolved to, in order. The count is the renderer's
    /// cost model made observable: prose alone must resolve to one.
    var segmentViewsForTesting: [NSView] { segmentViews }
}

/// A `---` rule, with its own air above and below.
@MainActor
final class AgentMarkdownRuleView: NSView {
    init(theme: DesignTokens.ChromeTheme) {
        super.init(frame: .zero)
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = theme.hairline.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        setAccessibilityElement(false)
        let spacing = DesignTokens.Component.agentTranscriptRuleSpacingPX
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor, constant: spacing),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -spacing),
            rule.heightAnchor.constraint(equalToConstant: DesignTokens.Component.hairlinePX),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A block quote, or a list item whose content is richer than a tab stop can
/// carry. Both are the same shape — something in the margin, a document beside
/// it — so they are one view rather than two nearly identical ones.
@MainActor
final class AgentMarkdownNestedView: NSView {
    init(
        container: AgentMarkdownSegment.Container,
        blocks: [AgentMarkdownBlock],
        theme: DesignTokens.ChromeTheme
    ) {
        super.init(frame: .zero)

        let body = AgentMarkdownDocumentView(blocks: blocks, theme: theme, insetX: 0, insetY: 0)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)

        let margin: NSView
        let bodyIndent: CGFloat
        switch container {
        case .quote:
            setAccessibilityLabel(AppLocalization.string(.transcriptQuoteAccessibility))
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = theme.borderStrong.cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(
                    equalToConstant: DesignTokens.Component.agentTranscriptQuoteBarWidthPX
                ),
                bar.topAnchor.constraint(equalTo: topAnchor),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            margin = bar
            bodyIndent = DesignTokens.Component.agentTranscriptQuoteBarWidthPX
                + DesignTokens.Component.agentTranscriptQuoteIndentPX
        case let .listItem(marker):
            let label = NSTextField(labelWithString: marker)
            label.font = AgentMarkdownFlowComposer.bodyFont
            label.textColor = theme.textSecondary
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor),
            ])
            margin = label
            bodyIndent = DesignTokens.Component.agentTranscriptListMarkerColumnPX
        }

        NSLayoutConstraint.activate([
            margin.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: bodyIndent),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
