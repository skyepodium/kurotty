import AppKit
import KurottyCore

/// The copy the exit banner shows, resolved from the exit alone.
///
/// Split out of the view so the wording for a clean exit, a nonzero status,
/// and a signal death can be asserted without building a window.
enum TerminalChildExitBannerText {
    static func title(for status: TerminalChildExitStatus) -> String {
        switch status {
        case let .exited(code) where code == 0:
            return AppLocalization.string(.childExitTitleClean)
        case let .exited(code):
            return AppLocalization.format(.childExitTitleCode, Int(code))
        case let .signalled(signal):
            return AppLocalization.format(.childExitTitleSignal, Int(signal))
        }
    }

    /// `nil` when the session never kept a start clock, which is what keeps the
    /// detail line off the banner instead of showing a fabricated "0s".
    static func runtimeDetail(for exit: TerminalChildExit) -> String? {
        guard let runtimeSeconds = exit.runtimeSeconds else {
            return nil
        }
        return AppLocalization.format(
            .childExitRanFor,
            TerminalChildExitRuntimeText.text(seconds: runtimeSeconds)
        )
    }
}

/// Floating notice shown over a pane whose child process has ended.
///
/// It deliberately does not cover the terminal: the pane keeps its scrollback,
/// so whatever the shell printed on its way out stays readable behind the card.
@MainActor
final class TerminalChildExitBannerView: NSView {
    var onRestart: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private lazy var restartButton = makeButton(
        title: AppLocalization.string(.childExitRestart),
        action: #selector(restartButtonPressed(_:))
    )
    private lazy var closeButton = makeButton(
        title: AppLocalization.string(.childExitClose),
        action: #selector(closeButtonPressed(_:))
    )
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var lastStatus = TerminalChildExitStatus.exited(code: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayout()
        applyChromeTheme(chromeTheme)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present(exit: TerminalChildExit) {
        lastStatus = exit.status
        titleField.stringValue = TerminalChildExitBannerText.title(for: exit.status)
        let detail = TerminalChildExitBannerText.runtimeDetail(for: exit)
        detailField.stringValue = detail ?? ""
        detailField.isHidden = detail == nil
        applyTextColors()
        isHidden = false
    }

    func dismiss() {
        isHidden = true
    }

    /// The two actions as the buttons invoke them. Exposed because an
    /// `NSButton` target/action pair cannot be exercised without a window.
    func performRestartForTesting() {
        restartButtonPressed(restartButton)
    }

    func performCloseForTesting() {
        closeButtonPressed(closeButton)
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = theme.surfaceRaised.cgColor
        layer?.borderColor = theme.hairline.cgColor
        layer.map(DesignTokens.Elevation.floating(for: theme).apply(to:))
        applyTextColors()
    }

    /// A clean exit is information; a nonzero status or a signal is a failure
    /// the title has to carry, so only that case earns the error hue.
    private func applyTextColors() {
        DesignTokens.Typography.rowTitleSel.apply(
            to: titleField,
            color: lastStatus.isCleanExit ? chromeTheme.textPrimary : chromeTheme.error
        )
        DesignTokens.Typography.rowSecondary.apply(to: detailField, color: chromeTheme.textSecondary)
    }

    private func configureLayout() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Component.childExitBannerCornerRadiusPX
        layer?.borderWidth = DesignTokens.Component.hairlinePX
        // The banner either is on screen or is not; a fade would read as the
        // terminal still doing something.
        layer.map(ChromeMotion.disableImplicitAnimations(on:))

        titleField.lineBreakMode = .byTruncatingTail
        detailField.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleField, detailField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = DesignTokens.Component.childExitBannerTextGapPX

        let buttonStack = NSStackView(views: [restartButton, closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = DesignTokens.Component.childExitBannerButtonGapPX

        let contentStack = NSStackView(views: [textStack, buttonStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = DesignTokens.Component.childExitBannerTextButtonGapPX
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        let maximumWidthConstraint = widthAnchor.constraint(
            lessThanOrEqualToConstant: DesignTokens.Component.childExitBannerMaxWidthPX
        )
        maximumWidthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            maximumWidthConstraint,
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DesignTokens.Component.childExitBannerPaddingXPX
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DesignTokens.Component.childExitBannerPaddingXPX
            ),
            contentStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: DesignTokens.Component.childExitBannerPaddingYPX
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -DesignTokens.Component.childExitBannerPaddingYPX
            ),
        ])
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = DesignTokens.Typography.rowTitle.font
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func restartButtonPressed(_ sender: NSButton) {
        onRestart?()
    }

    @objc private func closeButtonPressed(_ sender: NSButton) {
        onClose?()
    }
}
