import AppKit

struct PreferencesValidationStatus: Equatable {
    enum Kind: Equatable {
        case valid
        case warnings
        case errors
    }

    var kind: Kind
    var message: String
    var issues: [AppSettingsValidationIssue]

    var canSave: Bool {
        kind != .errors
    }
}

enum PreferencesValidationPresenter {
    static func status(
        for rawJSON: String,
        directoryExists: (String) -> Bool = defaultDirectoryExists
    ) -> PreferencesValidationStatus {
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(rawJSON.utf8))
            let report = AppSettingsValidation.report(for: settings, directoryExists: directoryExists)
            return status(for: report)
        } catch {
            return PreferencesValidationStatus(
                kind: .errors,
                message: "Errors: Settings JSON is invalid: \(error.localizedDescription)",
                issues: []
            )
        }
    }

    private static func status(for report: AppSettingsValidationReport) -> PreferencesValidationStatus {
        let errors = report.issues.filter { $0.severity == .error }
        if !errors.isEmpty {
            return PreferencesValidationStatus(
                kind: .errors,
                message: "Errors: \(summary(for: errors))",
                issues: report.issues
            )
        }

        let warnings = report.issues.filter { $0.severity == .warning }
        if !warnings.isEmpty {
            return PreferencesValidationStatus(
                kind: .warnings,
                message: "Warnings: \(summary(for: warnings))",
                issues: report.issues
            )
        }

        return PreferencesValidationStatus(
            kind: .valid,
            message: "Settings valid.",
            issues: report.issues
        )
    }

    private static func summary(for issues: [AppSettingsValidationIssue]) -> String {
        issues.map(\.message).joined(separator: " ")
    }

    private static func defaultDirectoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

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
final class PreferencesView: NSView, NSTextViewDelegate {
    private enum Layout {
        static let windowPadding = DesignTokens.Space.preferencesInsetPX
        static let controlSpacing = DesignTokens.Space.preferencesGapPX
        static let statusHeight = DesignTokens.Component.preferencesStatusHeightPX
        static let editorFontSize = DesignTokens.Component.settingsEditorFontSizePT
    }

    private static let autosaveDelay: TimeInterval = 0.35

    private let store: AppSettingsStore
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var autosaveWorkItem: DispatchWorkItem?
    private var isLoadingFromDisk = false

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
        textView.delegate = self
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

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

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
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .medium)
        return field
    }

    private func reloadFromDisk() {
        do {
            isLoadingFromDisk = true
            textView.string = try store.loadRawJSON()
            isLoadingFromDisk = false
            let status = PreferencesValidationPresenter.status(for: textView.string)
            setStatus("Loaded \(store.settingsURL.path). Edits apply automatically. \(status.message)")
        } catch {
            isLoadingFromDisk = false
            setStatus("Load failed: \(error.localizedDescription)")
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoadingFromDisk else {
            return
        }

        let status = PreferencesValidationPresenter.status(for: textView.string)
        guard status.canSave else {
            autosaveWorkItem?.cancel()
            setStatus("Not applied. \(status.message)")
            return
        }

        setStatus("Applying settings. \(status.message)")
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.autosaveCurrentSettings()
            }
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: workItem)
    }

    private func autosaveCurrentSettings() {
        let status = PreferencesValidationPresenter.status(for: textView.string)
        guard status.canSave else {
            setStatus("Not applied. \(status.message)")
            return
        }

        do {
            try store.save(rawJSON: textView.string)
            setStatus("Applied \(store.settingsURL.path). \(status.message)")
        } catch {
            setStatus("Apply failed: \(error.localizedDescription)")
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }
}
