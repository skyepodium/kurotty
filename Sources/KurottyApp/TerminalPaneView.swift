import AppKit

final class TerminalPaneView: NSView {
    private let chromeView = PaneChromeView()
    private let activeIndicatorView = NSView()
    private let titleField = NSTextField(labelWithString: "~ (-zsh)")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let terminalSurfaceView = TerminalSurfaceView()
    private var chromeHeightConstraint: NSLayoutConstraint?
    private var isChromeActive = false
    private var isChromeHovered = false
    var closeRequested: ((TerminalPaneView) -> Void)?
    var focusChanged: ((TerminalPaneView) -> Void)?

    var terminalSurface: TerminalSurfaceView {
        terminalSurfaceView
    }

    var ownsFirstResponder: Bool {
        guard let firstResponder = window?.firstResponder else {
            return false
        }
        guard let firstResponderView = firstResponder as? NSView else {
            return firstResponder === terminalSurfaceView
        }
        return firstResponderView === self
            || firstResponderView === terminalSurfaceView
            || firstResponderView.isDescendant(of: self)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        configureLayout()
        observeTerminalTitle()
        observeTerminalFocus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureLayout() {
        chromeView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.onHoverChanged = { [weak self] isHovered in
            self?.isChromeHovered = isHovered
            self?.updateChromeAppearance()
        }
        chromeView.onSelect = { [weak self] in
            self?.focusTerminal()
        }
        addSubview(chromeView)

        activeIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        activeIndicatorView.wantsLayer = true
        activeIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        chromeView.addSubview(activeIndicatorView)

        titleField.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .medium)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(titleField)

        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed(_:))
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .medium)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(closeButton)

        terminalSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalSurfaceView)

        let chromeHeightConstraint = chromeView.heightAnchor.constraint(equalToConstant: 0)
        self.chromeHeightConstraint = chromeHeightConstraint
        NSLayoutConstraint.activate([
            chromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeView.topAnchor.constraint(equalTo: topAnchor),
            chromeHeightConstraint,

            activeIndicatorView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor),
            activeIndicatorView.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor),
            activeIndicatorView.topAnchor.constraint(equalTo: chromeView.topAnchor),
            activeIndicatorView.heightAnchor.constraint(equalToConstant: 3),

            titleField.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            titleField.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeCloseWidthPX),
            closeButton.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeHeightPX - 4),

            terminalSurfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalSurfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalSurfaceView.topAnchor.constraint(equalTo: chromeView.bottomAnchor),
            terminalSurfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setChromeVisible(false)
        updateChromeAppearance()
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(terminalSurfaceView)
    }

    func focusTerminal() {
        window?.makeFirstResponder(terminalSurfaceView)
    }

    func setChromeVisible(_ isVisible: Bool) {
        chromeHeightConstraint?.constant = isVisible ? DesignTokens.Component.terminalPaneChromeHeightPX : 0
        chromeView.isHidden = !isVisible
    }

    func setChromeActive(_ isActive: Bool) {
        isChromeActive = isActive
        updateChromeAppearance()
    }

    @objc private func closeButtonPressed(_ sender: NSButton) {
        closeRequested?(self)
    }

    private func updateChromeAppearance() {
        let background: NSColor
        if isChromeActive {
            background = isChromeHovered
                ? NSColor(calibratedRed: 0.78, green: 0.86, blue: 1.00, alpha: 1)
                : NSColor(calibratedRed: 0.84, green: 0.90, blue: 1.00, alpha: 1)
        } else {
            background = isChromeHovered
                ? NSColor(calibratedWhite: 0.86, alpha: 1)
                : NSColor(calibratedWhite: 0.90, alpha: 1)
        }
        activeIndicatorView.isHidden = !isChromeActive
        chromeView.layer?.backgroundColor = background.cgColor
        chromeView.layer?.borderWidth = isChromeActive ? 1.5 : 0
        chromeView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        titleField.font = isChromeActive
            ? NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .semibold)
            : NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .medium)
        titleField.textColor = isChromeActive || isChromeHovered ? .labelColor : .secondaryLabelColor
        closeButton.contentTintColor = isChromeActive || isChromeHovered ? .labelColor : .secondaryLabelColor
    }

    private func observeTerminalTitle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalTitleDidChange(_:)),
            name: TerminalSurfaceView.titleDidChangeNotification,
            object: terminalSurfaceView
        )
    }

    private func observeTerminalFocus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalFocusDidChange(_:)),
            name: TerminalSurfaceView.focusDidChangeNotification,
            object: terminalSurfaceView
        )
    }

    @objc private func terminalFocusDidChange(_ notification: Notification) {
        focusChanged?(self)
    }

    @objc private func terminalTitleDidChange(_ notification: Notification) {
        guard let title = notification.userInfo?[TerminalSurfaceView.titleNotificationKey] as? String else {
            return
        }
        titleField.stringValue = title
    }
}

private final class PaneChromeView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onSelect: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}
