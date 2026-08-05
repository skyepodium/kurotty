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

    static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "icns", "bmp", "heic", "heif", "tiff", "webp", "svg"
    ]

    static func isImageFile(at url: URL) -> Bool {
        imageFileExtensions.contains(url.pathExtension.lowercased())
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

    /// Whether the buffer has unsaved edits. Owners consult this before
    /// closing a hosting tab.
    var isModified: Bool {
        dirtyTracker.isDirty
    }

    var isShowingImageForTesting: Bool {
        !imagePreviewView.isHidden && imagePreviewView.image != nil
    }

    var isReadOnly = false {
        didSet { textView.isEditable = !isReadOnly && isShowingText }
    }

    private let pathBar = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = TerminalCodeEditorTextView()
    private let imagePreviewView = TerminalImagePreviewView()
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

        if TerminalCodeEditorDocumentPolicy.isImageFile(at: url) {
            showImage(at: url)
            _ = dirtyTracker.noteLoaded()
            callbacks.onModifiedChanged?(false)
            updatePathBar()
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            showPlaceholder(.editorLoadFailed)
            return
        }
        switch TerminalCodeEditorDocumentPolicy.classify(data: data) {
        case .binary:
            showPlaceholder(.editorBinaryFile)
        case .tooLarge:
            showPlaceholder(.editorFileTooLarge)
        case .text(let text):
            showText(text)
        }
        if dirtyTracker.noteLoaded() {
            callbacks.onModifiedChanged?(false)
        }
        updatePathBar()
    }

    /// Scrolls to and selects a 1-based `line`, optionally placing the caret at
    /// `column`. Used by `path:line:col` terminal links. Out-of-range lines are
    /// ignored rather than clamped, so a stale line number is a no-op.
    func scrollTo(line: Int, column: Int? = nil) {
        guard isShowingText else { return }
        let text = textView.string
        guard let lineRange = TerminalCodeEditorLineRange.characterRange(forLine: line, in: text)
        else { return }
        let selection = TerminalCodeEditorLineRange.caretRange(
            forLine: line,
            column: column,
            in: text
        ) ?? lineRange
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(lineRange)
        textView.showFindIndicator(for: lineRange)
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
            width: DesignTokens.Component.codeEditorTextInsetXPX,
            height: DesignTokens.Component.codeEditorTextInsetYPX
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

        imagePreviewView.translatesAutoresizingMaskIntoConstraints = false
        imagePreviewView.isHidden = true
        addSubview(imagePreviewView)

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
            pathBar.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Component.codeEditorPathBarInsetYPX),
            pathBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Component.codeEditorPathBarInsetXPX),
            pathBar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DesignTokens.Component.codeEditorPathBarInsetXPX),

            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: DesignTokens.Component.codeEditorPathBarInsetYPX),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imagePreviewView.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: DesignTokens.Component.codeEditorPathBarInsetYPX),
            imagePreviewView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imagePreviewView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imagePreviewView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    // MARK: - Content states

    private func showText(_ text: String) {
        isShowingText = true
        placeholderLabel.isHidden = true
        textView.isHidden = false
        imagePreviewView.isHidden = true
        scrollView.rulersVisible = true
        textView.isEditable = !isReadOnly
        textView.string = text
        rehighlight()
        rulerView?.invalidateLineIndex()
        textView.scrollToBeginningOfDocument(nil)
    }

    private func showImage(at url: URL) {
        isShowingText = false
        placeholderLabel.isHidden = true
        textView.isEditable = false
        textView.isHidden = true
        scrollView.rulersVisible = false
        rulerView?.invalidateLineIndex()
        if let image = NSImage(contentsOf: url) {
            imagePreviewView.image = image
            imagePreviewView.isHidden = false
            return
        }
        showPlaceholder(.editorLoadFailed)
    }

    private func showPlaceholder(_ key: L10nKey) {
        isShowingText = false
        textView.string = ""
        textView.isHidden = true
        textView.isEditable = false
        imagePreviewView.isHidden = true
        scrollView.rulersVisible = false
        placeholderLabel.stringValue = AppLocalization.string(key)
        placeholderLabel.isHidden = false
        rulerView?.invalidateLineIndex()
    }

    // MARK: - Appearance

    private var editorFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: DesignTokens.Typography.codeEditorFontSizePT,
            weight: .regular
        )
    }

    private func applyPalette() {
        layer?.backgroundColor = palette.chromeBackground.cgColor
        scrollView.backgroundColor = palette.editorBackground
        imagePreviewView.backgroundColor = palette.editorBackground
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
                string: " " + TerminalCodeEditorConstants.modifiedDotGlyph,
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
            && event.charactersIgnoringModifiers?.lowercased() == TerminalCodeEditorConstants.saveKeyCharacter
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
        ruleThickness = DesignTokens.Component.codeEditorGutterWidthPX
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
        let font = NSFont.monospacedDigitSystemFont(ofSize: DesignTokens.Typography.codeEditorGutterFontSizePT, weight: .regular)
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
            x: ruleThickness - size.width - DesignTokens.Component.codeEditorGutterLabelTrailingPX,
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

/// Read-only image canvas used by editor tabs. It keeps the image centered and
/// aspect-fitted as the terminal window resizes instead of exposing an
/// arbitrary top-left crop of the source bitmap.
@MainActor
final class TerminalImagePreviewView: NSView {
    var image: NSImage? {
        didSet {
            setAccessibilityLabel(image == nil ? "" : AppLocalization.string(.fileExplorer))
            needsDisplay = true
        }
    }

    var backgroundColor = NSColor.clear {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }

        let availableRect = bounds.insetBy(
            dx: DesignTokens.Component.imagePreviewInsetPX,
            dy: DesignTokens.Component.imagePreviewInsetPX
        )
        guard availableRect.width > 0, availableRect.height > 0 else { return }
        let scale = min(
            1,
            min(availableRect.width / image.size.width, availableRect.height / image.size.height)
        )
        let fittedSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let fittedRect = NSRect(
            x: availableRect.midX - fittedSize.width / 2,
            y: availableRect.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
        image.draw(
            in: fittedRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
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
            keyword: TerminalCodeEditorSyntaxColors.syntaxKeyword,
            string: theme.success,
            comment: theme.textMuted,
            number: theme.warning,
            typeName: DesignTokens.Color.cyanTerminalAccent
        )
    }
}

/// Syntax hues that are not chrome roles. Purple used to live in
/// `DesignTokens.Color` as `accentPurple` and leaked into chrome (status dots,
/// active borders); it now survives only here, as a keyword color.
enum TerminalCodeEditorSyntaxColors {
    static let syntaxKeyword = NSColor.designTokenSRGB(0x8B_5C_F6)
}

/// Editor-local domain constants that are not design tokens: the modified-state
/// glyph and the save key equivalent. Layout/typography values live in
/// `DesignTokens.Component` and `DesignTokens.Typography`.
enum TerminalCodeEditorConstants {
    static let modifiedDotGlyph = "●"
    static let saveKeyCharacter = "s"
}
