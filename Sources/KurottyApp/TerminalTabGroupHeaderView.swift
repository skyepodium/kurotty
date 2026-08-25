import AppKit

@MainActor
final class TerminalTabGroupHeaderView: NSView {
    private let colorDotView = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let disclosureField = NSTextField(labelWithString: "")
    private let group: TerminalTabGroup
    private let chromeTheme: DesignTokens.ChromeTheme
    private let onToggleCollapsed: () -> Void
    private let menuProvider: () -> NSMenu?

    init(
        group: TerminalTabGroup,
        chromeTheme: DesignTokens.ChromeTheme,
        onToggleCollapsed: @escaping () -> Void,
        menuProvider: @escaping () -> NSMenu?
    ) {
        self.group = group
        self.chromeTheme = chromeTheme
        self.onToggleCollapsed = onToggleCollapsed
        self.menuProvider = menuProvider
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type != .rightMouseDown else {
            NSMenu.popUpContextMenu(menuProvider() ?? NSMenu(), with: event, for: self)
            return
        }
        onToggleCollapsed()
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider() ?? NSMenu(), with: event, for: self)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.backgroundColor = chromeTheme.hoverFill.cgColor
        layer?.cornerRadius = DesignTokens.Radius.smPX
        layer?.masksToBounds = true

        colorDotView.translatesAutoresizingMaskIntoConstraints = false
        colorDotView.wantsLayer = true
        colorDotView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        colorDotView.layer?.backgroundColor = TerminalTabGroupPalette.color(for: group, theme: chromeTheme).cgColor
        colorDotView.layer?.cornerRadius = DesignTokens.UIScale.scaledMetric(3)
        addSubview(colorDotView)

        titleField.stringValue = group.name
        titleField.lineBreakMode = .byTruncatingTail
        DesignTokens.Typography.tabLabel.apply(to: titleField, color: chromeTheme.textSecondary)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        disclosureField.stringValue = group.isCollapsed ? ">" : "v"
        DesignTokens.Typography.tabLabel.apply(to: disclosureField, color: chromeTheme.textTertiary)
        disclosureField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabHeightPX),
            widthAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.UIScale.scaledMetric(88)),

            colorDotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Space.x3PX),
            colorDotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorDotView.widthAnchor.constraint(equalToConstant: DesignTokens.UIScale.scaledMetric(6)),
            colorDotView.heightAnchor.constraint(equalTo: colorDotView.widthAnchor),

            titleField.leadingAnchor.constraint(equalTo: colorDotView.trailingAnchor, constant: DesignTokens.Space.x2PX),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            disclosureField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: DesignTokens.Space.x2PX),
            disclosureField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Space.x3PX),
            disclosureField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
