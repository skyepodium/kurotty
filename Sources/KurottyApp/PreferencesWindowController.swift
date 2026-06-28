import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    init() {
        let view = PreferencesView(frame: NSRect(
            x: 0,
            y: 0,
            width: DesignTokens.Component.preferencesWidthPX,
            height: DesignTokens.Component.preferencesHeightPX
        ))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppConstants.Bundle.displayName) Settings"
        window.contentView = view
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

@MainActor
final class PreferencesView: NSView {
    private enum Layout {
        static let windowPadding = DesignTokens.Space.preferencesInsetPX
        static let controlSpacing = DesignTokens.Space.preferencesGapPX
        static let statusHeight = DesignTokens.Component.preferencesStatusHeightPX
        static let buttonWidth = DesignTokens.Component.preferencesButtonWidthPX
        static let buttonHeight = DesignTokens.Component.preferencesButtonHeightPX
        static let editorFontSize = DesignTokens.Component.settingsEditorFontSizePT
    }

    private let store: AppSettingsStore
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)

    init(frame frameRect: NSRect, store: AppSettingsStore = .shared) {
        self.store = store
        super.init(frame: frameRect)
        configure()
        reloadFromDisk()
    }

    override init(frame frameRect: NSRect) {
        store = .shared
        super.init(frame: frameRect)
        configure()
        reloadFromDisk()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure() {
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView

        textView.autoresizingMask = [.width, .height]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: Layout.editorFontSize, weight: .regular)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        saveButton.target = self
        saveButton.action = #selector(saveToDisk)
        saveButton.bezelStyle = .rounded
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        reloadButton.target = self
        reloadButton.action = #selector(reloadFromDisk)
        reloadButton.bezelStyle = .rounded
        reloadButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [reloadButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = Layout.controlSpacing
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Layout.controlSpacing
        stack.edgeInsets = NSEdgeInsets(
            top: Layout.windowPadding,
            left: Layout.windowPadding,
            bottom: Layout.windowPadding,
            right: Layout.windowPadding
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label("settings.json"))
        stack.addArrangedSubview(scrollView)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(buttonStack)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Layout.windowPadding * 2),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.Component.preferencesControlWidthPX),
            statusLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: Layout.statusHeight),
            saveButton.widthAnchor.constraint(equalToConstant: Layout.buttonWidth),
            reloadButton.widthAnchor.constraint(equalToConstant: Layout.buttonWidth),
            saveButton.heightAnchor.constraint(equalToConstant: Layout.buttonHeight),
            reloadButton.heightAnchor.constraint(equalToConstant: Layout.buttonHeight),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .medium)
        return field
    }

    @objc private func reloadFromDisk() {
        do {
            textView.string = try store.loadRawJSON()
            setStatus("Loaded \(store.settingsURL.path)")
        } catch {
            setStatus("Reload failed: \(error.localizedDescription)")
        }
    }

    @objc private func saveToDisk() {
        do {
            try store.save(rawJSON: textView.string)
            setStatus("Saved \(store.settingsURL.path)")
        } catch {
            setStatus("Save failed: \(error.localizedDescription)")
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }
}
