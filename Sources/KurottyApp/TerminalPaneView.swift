import AppKit

final class TerminalPaneView: NSView {
    private let chromeView = PaneChromeView()
    private let activeIndicatorView = NSView()
    private let statusDotView = NSView()
    private let titleField = NSTextField(labelWithString: "~ (-zsh)")
    private let closeButton = ChromeIconButton(title: "×", target: nil, action: nil)
    private let terminalSurfaceView = TerminalSurfaceView()
    private var chromeHeightConstraint: NSLayoutConstraint?
    private var isChromeActive = false
    private var isChromeHovered = false
    var closeRequested: ((TerminalPaneView) -> Void)?
    var focusChanged: ((TerminalPaneView) -> Void)?
    var detachDragRequested: ((TerminalPaneView, NSEvent) -> Void)?

    var terminalSurface: TerminalSurfaceView {
        terminalSurfaceView
    }

    var displayTitle: String {
        titleField.stringValue
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
        layer?.backgroundColor = DesignTokens.Color.windowBackground.cgColor
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
        chromeView.onDragRequested = { [weak self] event in
            guard let self else {
                return
            }
            self.beginDraggingPane(self, with: event)
        }
        addSubview(chromeView)

        activeIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        activeIndicatorView.wantsLayer = true
        activeIndicatorView.layer?.backgroundColor = DesignTokens.Color.accentPurple.cgColor
        chromeView.addSubview(activeIndicatorView)

        statusDotView.translatesAutoresizingMaskIntoConstraints = false
        statusDotView.wantsLayer = true
        statusDotView.layer?.cornerRadius = DesignTokens.Component.terminalPaneChromeDotSizePX / 2
        chromeView.addSubview(statusDotView)

        titleField.font = NSFont.systemFont(ofSize: DesignTokens.Typography.paneHeaderFontSizePT, weight: .medium)
        titleField.textColor = DesignTokens.Color.textSecondary
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(titleField)

        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed(_:))
        closeButton.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .medium)
        closeButton.normalTintColor = DesignTokens.Color.textMuted
        closeButton.hoverTintColor = DesignTokens.Color.textPrimary
        closeButton.hoverBackgroundColor = DesignTokens.Color.inactiveTabHoverBackground
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
            activeIndicatorView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
            activeIndicatorView.heightAnchor.constraint(equalToConstant: 2),

            statusDotView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor, constant: 12),
            statusDotView.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),
            statusDotView.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeDotSizePX),
            statusDotView.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeDotSizePX),

            titleField.leadingAnchor.constraint(equalTo: statusDotView.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            titleField.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeCloseWidthPX),
            closeButton.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalPaneChromeCloseWidthPX),

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

    func beginDraggingPane(_ pane: TerminalPaneView, with event: NSEvent) {
        detachDragRequested?(pane, event)
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
                ? DesignTokens.Color.paneHeaderHoverBackground
                : DesignTokens.Color.paneHeaderBackground
        } else {
            background = isChromeHovered
                ? DesignTokens.Color.paneHeaderHoverBackground
                : DesignTokens.Color.paneHeaderBackground
        }
        activeIndicatorView.isHidden = !isChromeActive
        statusDotView.layer?.backgroundColor = (isChromeActive
            ? DesignTokens.Color.successGreen
            : DesignTokens.Color.accentPurple.withAlphaComponent(0.75)).cgColor
        chromeView.layer?.backgroundColor = background.cgColor
        chromeView.layer?.borderWidth = DesignTokens.Component.hairlinePX
        chromeView.layer?.borderColor = DesignTokens.Color.borderHairline.cgColor
        titleField.font = isChromeActive
            ? NSFont.systemFont(ofSize: DesignTokens.Typography.paneHeaderFontSizePT, weight: .semibold)
            : NSFont.systemFont(ofSize: DesignTokens.Typography.paneHeaderFontSizePT, weight: .medium)
        titleField.textColor = isChromeActive || isChromeHovered ? DesignTokens.Color.textPrimary : DesignTokens.Color.textSecondary
        closeButton.normalTintColor = isChromeActive || isChromeHovered ? DesignTokens.Color.textSecondary : DesignTokens.Color.textMuted
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
    private enum Drag {
        static let thresholdPX: CGFloat = 4
    }

    var onHoverChanged: ((Bool) -> Void)?
    var onSelect: (() -> Void)?
    var onDragRequested: ((NSEvent) -> Void)?
    private var mouseDownLocationInWindow = NSPoint.zero

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
        mouseDownLocationInWindow = event.locationInWindow
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        let dragDeltaX = abs(event.locationInWindow.x - mouseDownLocationInWindow.x)
        let dragDeltaY = abs(event.locationInWindow.y - mouseDownLocationInWindow.y)
        guard max(dragDeltaX, dragDeltaY) >= Drag.thresholdPX else {
            return
        }
        onDragRequested?(event)
    }
}
