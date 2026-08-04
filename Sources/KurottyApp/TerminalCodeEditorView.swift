import AppKit

/// Wiring surface for the future file-explorer coordinator. The editor calls
/// these when its tab title or modified state should change.
struct TerminalCodeEditorCallbacks {
    var onTitleChanged: ((String) -> Void)?
    var onModifiedChanged: ((Bool) -> Void)?

    init(
        onTitleChanged: ((String) -> Void)? = nil,
        onModifiedChanged: ((Bool) -> Void)? = nil
    ) {
        self.onTitleChanged = onTitleChanged
        self.onModifiedChanged = onModifiedChanged
    }
}

/// Pure, testable load policy: decides whether raw file bytes become editable
/// text, a binary placeholder, or a too-large placeholder.
enum TerminalCodeEditorDocumentPolicy {
    /// Files above this byte size show a placeholder instead of loading.
    static let fileSizeCapBytes = 5 * 1024 * 1024
    /// Only this prefix is probed for NUL bytes during binary detection.
    static let binaryProbePrefixBytes = 8192

    enum LoadClassification: Equatable {
        case text(String)
        case binary
        case tooLarge
    }

    static func classify(data: Data) -> LoadClassification {
        guard data.count <= fileSizeCapBytes else { return .tooLarge }
        guard !isBinary(data: data) else { return .binary }
        if let text = String(data: data, encoding: .utf8) {
            return .text(text)
        }
        return .text(String(decoding: data, as: UTF8.self))
    }

    static func isBinary(data: Data) -> Bool {
        data.prefix(binaryProbePrefixBytes).contains(0)
    }
}

/// Pure dirty-state model. Transition methods return `true` when the modified
/// flag actually changed so the owner only fires callbacks on transitions.
struct TerminalCodeEditorDirtyTracker: Equatable {
    private(set) var isDirty = false

    mutating func noteLoaded() -> Bool {
        setDirty(false)
    }

    mutating func noteTextChanged() -> Bool {
        setDirty(true)
    }

    mutating func noteSaved() -> Bool {
        setDirty(false)
    }

    private mutating func setDirty(_ newValue: Bool) -> Bool {
        guard isDirty != newValue else { return false }
        isDirty = newValue
        return true
    }
}

/// Read-only code viewer/editor shown as a center tab when a file is opened
/// from the file explorer. Path bar on top, line-number gutter on the left,
/// monospaced text with light syntax highlighting from
/// `TerminalCodeSyntaxHighlighter` (whole-document re-highlight per edit; see
/// that file for the documented incremental strategy).
@MainActor
final class TerminalCodeEditorView: NSView {
    private(set) var fileURL: URL?
    var callbacks = TerminalCodeEditorCallbacks()

    var isReadOnly = false {
        didSet { textView.isEditable = !isReadOnly && isShowingText }
    }

    private let pathBar = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = TerminalCodeEditorTextView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var rulerView: TerminalCodeEditorLineNumberRulerView?
    private var dirtyTracker = TerminalCodeEditorDirtyTracker()
    private var language = CodeSyntaxLanguage.plain
    private var palette = TerminalCodeEditorPalette.palette(for: .dark)
    private var isShowingText = false

    init(callbacks: TerminalCodeEditorCallbacks = TerminalCodeEditorCallbacks()) {
        self.callbacks = callbacks
        super.init(frame: .zero)
        configureSubviews()
        applyPalette()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Public API

    func load(url: URL) {
        fileURL = url
        language = CodeSyntaxLanguage(fileExtension: url.pathExtension)
        callbacks.onTitleChanged?(url.lastPathComponent)

        guard let data = try? Data(contentsOf: url) else {
            showPlaceholder(.loadFailed)
            return
        }
        switch TerminalCodeEditorDocumentPolicy.classify(data: data) {
        case .binary:
            showPlaceholder(.binaryFile)
        case .tooLarge:
            showPlaceholder(.fileTooLarge)
        case .text(let text):
            showText(text)
        }
        if dirtyTracker.noteLoaded() {
            callbacks.onModifiedChanged?(false)
        }
        updatePathBar()
    }

    func save() {
        guard let url = fileURL, isShowingText, !isReadOnly else { return }
        // Write the buffer exactly as edited; trailing-newline state is
        // whatever the user left in the buffer.
        guard let data = textView.string.data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        if dirtyTracker.noteSaved() {
            callbacks.onModifiedChanged?(false)
        }
        updatePathBar()
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        palette = TerminalCodeEditorPalette.palette(for: theme)
        applyPalette()
        rehighlight()
        updatePathBar()
    }

    // MARK: - Layout

    private func configureSubviews() {
        wantsLayer = true

        pathBar.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT)
        pathBar.lineBreakMode = .byTruncatingHead
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathBar)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = editorFont
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(
            width: Metrics.textInsetXPX,
            height: Metrics.textInsetYPX
        )
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.onSaveKeyEquivalent = { [weak self] in
            self?.save()
        }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let ruler = TerminalCodeEditorLineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        rulerView = ruler

        placeholderLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT)
        placeholderLabel.alignment = .center
        placeholderLabel.isHidden = true
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.pathBarInsetYPX),
            pathBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.pathBarInsetXPX),
            pathBar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.pathBarInsetXPX),

            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: Metrics.pathBarInsetYPX),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    // MARK: - Content states

    private func showText(_ text: String) {
        isShowingText = true
        placeholderLabel.isHidden = true
        textView.isHidden = false
        textView.isEditable = !isReadOnly
        textView.string = text
        rehighlight()
        rulerView?.invalidateLineIndex()
        textView.scrollToBeginningOfDocument(nil)
    }

    private func showPlaceholder(_ key: TerminalCodeEditorCopy.Key) {
        isShowingText = false
        textView.string = ""
        textView.isHidden = true
        textView.isEditable = false
        placeholderLabel.stringValue = TerminalCodeEditorCopy.string(key)
        placeholderLabel.isHidden = false
        rulerView?.invalidateLineIndex()
    }

    // MARK: - Appearance

    private var editorFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: Metrics.codeFontSizePT,
            weight: .regular
        )
    }

    private func applyPalette() {
        layer?.backgroundColor = palette.chromeBackground.cgColor
        scrollView.backgroundColor = palette.editorBackground
        textView.backgroundColor = palette.editorBackground
        textView.textColor = palette.plainText
        textView.insertionPointColor = palette.plainText
        placeholderLabel.textColor = palette.mutedText
        rulerView?.applyPalette(palette)
    }

    private func updatePathBar() {
        guard let url = fileURL else {
            pathBar.attributedStringValue = NSAttributedString(string: "")
            return
        }
        let directory = url.deletingLastPathComponent().path
        let font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT)
        let boldFont = NSFont.boldSystemFont(ofSize: DesignTokens.Typography.labelFontSizePT)
        let value = NSMutableAttributedString()
        value.append(NSAttributedString(
            string: directory + "/",
            attributes: [.foregroundColor: palette.mutedText, .font: font]
        ))
        value.append(NSAttributedString(
            string: url.lastPathComponent,
            attributes: [.foregroundColor: palette.primaryText, .font: boldFont]
        ))
        if dirtyTracker.isDirty {
            value.append(NSAttributedString(
                string: " " + Metrics.modifiedDotGlyph,
                attributes: [.foregroundColor: palette.modifiedDot, .font: font]
            ))
        }
        pathBar.attributedStringValue = value
    }

    private func rehighlight() {
        guard isShowingText, let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(
            [.foregroundColor: palette.plainText, .font: editorFont],
            range: fullRange
        )
        let tokens = TerminalCodeSyntaxHighlighter.highlight(text: textView.string, language: language)
        for token in tokens {
            storage.addAttribute(
                .foregroundColor,
                value: palette.color(for: token.kind),
                range: token.range
            )
        }
        storage.endEditing()
    }
}

extension TerminalCodeEditorView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        if dirtyTracker.noteTextChanged() {
            callbacks.onModifiedChanged?(true)
            updatePathBar()
        }
        rehighlight()
        rulerView?.invalidateLineIndex()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        rulerView?.needsDisplay = true
    }
}

/// Text view that keeps paste plain (the view is plain-text already, but paste
/// is routed through `pasteAsPlainText` defensively) and forwards Cmd+S.
@MainActor
final class TerminalCodeEditorTextView: NSTextView {
    var onSaveKeyEquivalent: (() -> Void)?

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCommandS = event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == Metrics.saveKeyCharacter
        if isCommandS {
            onSaveKeyEquivalent?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Theme-aware line-number gutter. Line starts are indexed lazily from the
/// backing string and invalidated on every text change; the current line is
/// drawn with the primary text color, other lines muted.
@MainActor
final class TerminalCodeEditorLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStartIndexes: [Int] = [0]
    private var lineIndexIsValid = false
    private var palette = TerminalCodeEditorPalette.palette(for: .dark)

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = Metrics.gutterWidthPX
        clientView = textView
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyPalette(_ newPalette: TerminalCodeEditorPalette) {
        palette = newPalette
        needsDisplay = true
    }

    func invalidateLineIndex() {
        lineIndexIsValid = false
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return
        }
        palette.gutterBackground.setFill()
        bounds.fill()

        rebuildLineIndexIfNeeded(text: textView.string as NSString)
        let currentLine = lineNumber(forCharacterIndex: textView.selectedRange().location)
        let font = NSFont.monospacedDigitSystemFont(ofSize: Metrics.gutterFontSizePT, weight: .regular)
        let inset = textView.textContainerInset.height
        let originOffset = convert(NSPoint.zero, from: textView).y

        guard layoutManager.numberOfGlyphs > 0 else {
            let emptyRect = layoutManager.extraLineFragmentRect
            drawLineNumber(
                1,
                atY: emptyRect.minY + inset + originOffset,
                height: max(emptyRect.height, font.pointSize),
                emphasized: true,
                font: font
            )
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineIndex = lineNumber(forCharacterIndex: characterRange.location)
        while lineIndex < lineStartIndexes.count {
            let lineStart = lineStartIndexes[lineIndex]
            guard lineStart <= NSMaxRange(characterRange) else { break }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineStart)
            guard glyphIndex < layoutManager.numberOfGlyphs else { break }
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            drawLineNumber(
                lineIndex + 1,
                atY: fragmentRect.minY + inset + originOffset,
                height: fragmentRect.height,
                emphasized: lineIndex == currentLine,
                font: font
            )
            lineIndex += 1
        }
    }

    private func drawLineNumber(_ number: Int, atY yPosition: CGFloat, height: CGFloat, emphasized: Bool, font: NSFont) {
        let label = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: emphasized ? palette.primaryText : palette.mutedText,
        ]
        let size = label.size(withAttributes: attributes)
        let drawRect = NSRect(
            x: ruleThickness - size.width - Metrics.gutterLabelTrailingPX,
            y: yPosition + (height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        label.draw(in: drawRect, withAttributes: attributes)
    }

    private func rebuildLineIndexIfNeeded(text: NSString) {
        guard !lineIndexIsValid else { return }
        lineStartIndexes = [0]
        var searchIndex = 0
        while searchIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: searchIndex, length: 0))
            searchIndex = NSMaxRange(lineRange)
            if searchIndex < text.length {
                lineStartIndexes.append(searchIndex)
            }
        }
        lineIndexIsValid = true
    }

    private func lineNumber(forCharacterIndex characterIndex: Int) -> Int {
        var low = 0
        var high = lineStartIndexes.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStartIndexes[middle] <= characterIndex {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }
}

/// Colors for the editor derived from the active chrome theme so the view is
/// correct in both light and dark terminal themes. The editor background stays
/// in the terminal-background family per design.
@MainActor
struct TerminalCodeEditorPalette {
    let chromeBackground: NSColor
    let editorBackground: NSColor
    let gutterBackground: NSColor
    let plainText: NSColor
    let primaryText: NSColor
    let mutedText: NSColor
    let modifiedDot: NSColor
    let keyword: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let typeName: NSColor

    func color(for kind: CodeSyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .typeName: return typeName
        }
    }

    static func palette(for theme: DesignTokens.ChromeTheme) -> TerminalCodeEditorPalette {
        let isLight = theme.windowAppearance?.name == .aqua
        return TerminalCodeEditorPalette(
            chromeBackground: theme.topChromeBackground,
            editorBackground: isLight ? theme.activeTabBackground : DesignTokens.Color.terminalBackground,
            gutterBackground: isLight ? theme.paneHeaderBackground : DesignTokens.Color.windowBackground,
            plainText: theme.textPrimary,
            primaryText: theme.textPrimary,
            mutedText: theme.textMuted,
            modifiedDot: theme.activeIndicator,
            keyword: DesignTokens.Color.accentPurple,
            string: DesignTokens.Color.successGreen,
            comment: theme.textMuted,
            number: DesignTokens.Color.warningOrange,
            typeName: DesignTokens.Color.cyanTerminalAccent
        )
    }
}

/// Placeholder copy shown inside the editor. Kept as a private table for now;
/// migrate these keys into `AppLocalization` when the file-explorer
/// coordinator lands (AppLocalization.swift is owned by a concurrent change).
enum TerminalCodeEditorCopy {
    enum Key {
        case binaryFile
        case fileTooLarge
        case loadFailed
    }

    static func string(_ key: Key, language: AppLanguage = AppLocalization.language) -> String {
        translations[language]?[key] ?? translations[.english]?[key] ?? ""
    }

    private static let translations: [AppLanguage: [Key: String]] = [
        .english: [
            .binaryFile: "Binary file",
            .fileTooLarge: "File too large",
            .loadFailed: "Could not open file",
        ],
        .korean: [
            .binaryFile: "바이너리 파일",
            .fileTooLarge: "파일이 너무 큽니다",
            .loadFailed: "파일을 열 수 없습니다",
        ],
        .japanese: [
            .binaryFile: "バイナリファイル",
            .fileTooLarge: "ファイルが大きすぎます",
            .loadFailed: "ファイルを開けませんでした",
        ],
    ]
}

/// Editor-local layout constants. Sizing values that outlive this component
/// should migrate into `DesignTokens.Component` once concurrent edits to that
/// file settle.
private enum Metrics {
    static let codeFontSizePT: CGFloat = 13
    static let gutterFontSizePT: CGFloat = 11
    static let gutterWidthPX: CGFloat = 44
    static let gutterLabelTrailingPX: CGFloat = 8
    static let textInsetXPX: CGFloat = 6
    static let textInsetYPX: CGFloat = 8
    static let pathBarInsetXPX: CGFloat = 12
    static let pathBarInsetYPX: CGFloat = 8
    static let modifiedDotGlyph = "●"
    static let saveKeyCharacter = "s"
}
