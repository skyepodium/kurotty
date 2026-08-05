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

    private let pathBarContainer = NSView()
    private let pathBarSeparator = NSView()
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
        applyEditorSettings()
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
        layer.map(ChromeMotion.disableImplicitAnimations(on:))

        pathBarContainer.wantsLayer = true
        pathBarContainer.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        pathBarContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathBarContainer)

        pathBarSeparator.wantsLayer = true
        pathBarSeparator.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        pathBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        pathBarContainer.addSubview(pathBarSeparator)

        pathBar.font = DesignTokens.Typography.rowSecondary.font
        pathBar.lineBreakMode = .byTruncatingHead
        pathBar.maximumNumberOfLines = 1
        pathBar.cell?.lineBreakMode = .byTruncatingHead
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBarContainer.addSubview(pathBar)

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
        // AppKit's own find bar rather than a bespoke one: it brings Cmd+F,
        // Cmd+G, incremental highlighting, and the standard Find menu items for
        // free, and it already matches the system chrome the editor sits in.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(
            width: DesignTokens.Component.codeEditorTextInsetXPX,
            height: DesignTokens.Component.codeEditorTextInsetYPX
        )
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

        placeholderLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.controlLabel.sizePT)
        placeholderLabel.alignment = .center
        placeholderLabel.isHidden = true
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            pathBarContainer.topAnchor.constraint(equalTo: topAnchor),
            pathBarContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            pathBarContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            pathBarContainer.heightAnchor.constraint(equalToConstant: DesignTokens.Component.codeEditorPathBarHeightPX),

            pathBarSeparator.leadingAnchor.constraint(equalTo: pathBarContainer.leadingAnchor),
            pathBarSeparator.trailingAnchor.constraint(equalTo: pathBarContainer.trailingAnchor),
            pathBarSeparator.bottomAnchor.constraint(equalTo: pathBarContainer.bottomAnchor),
            pathBarSeparator.heightAnchor.constraint(equalToConstant: DesignTokens.Component.hairlinePX),

            pathBar.leadingAnchor.constraint(equalTo: pathBarContainer.leadingAnchor, constant: DesignTokens.Component.codeEditorPathBarInsetXPX),
            pathBar.trailingAnchor.constraint(lessThanOrEqualTo: pathBarContainer.trailingAnchor, constant: -DesignTokens.Component.codeEditorPathBarInsetXPX),
            pathBar.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),

            // Gap 0: the path bar carries its own hairline, so a second gap
            // would read as a floating label again.
            scrollView.topAnchor.constraint(equalTo: pathBarContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imagePreviewView.topAnchor.constraint(equalTo: pathBarContainer.bottomAnchor),
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

    /// Settings are read on demand rather than cached: an editor tab can be
    /// open across a settings change, and a stale copy would keep the old size.
    private static func editorSettings() -> TerminalSettings {
        ((try? AppSettingsStore.shared.load()) ?? .default).terminal
    }

    private var editorFont: NSFont {
        let size = Self.editorSettings().codeEditorFontSize
        return NSFont.monospacedSystemFont(
            ofSize: size > 0 ? size : DesignTokens.Typography.codeEditorFontSizePT,
            weight: .regular
        )
    }

    /// Re-reads the editor's own settings. Called on load and whenever settings
    /// change, so a size or wrap change lands in tabs that are already open
    /// rather than only in the next one.
    func applyEditorSettings() {
        textView.font = editorFont
        applyLineWrapping(Self.editorSettings().codeEditorWrapsLines)
        rehighlight()
    }

    /// Soft wrap folds long lines to the pane width; hard wrap lets them run and
    /// scrolls horizontally. The text container has to be resized either way,
    /// because a container left at the view width silently keeps folding.
    private func applyLineWrapping(_ wraps: Bool) {
        guard let container = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        if wraps {
            textView.autoresizingMask = [.width]
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            container.widthTracksTextView = true
            container.size = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        } else {
            textView.autoresizingMask = [.height]
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        textView.needsLayout = true
    }

    private func applyPalette() {
        layer?.backgroundColor = palette.chromeBackground.cgColor
        pathBarContainer.layer?.backgroundColor = palette.pathBarBackground.cgColor
        pathBarSeparator.layer?.backgroundColor = palette.hairline.cgColor
        scrollView.backgroundColor = palette.editorBackground
        imagePreviewView.backgroundColor = palette.editorBackground
        textView.backgroundColor = palette.editorBackground
        textView.textColor = palette.plainText
        textView.insertionPointColor = palette.plainText
        placeholderLabel.textColor = palette.mutedText
        rulerView?.applyPalette(palette)
    }

    /// Renders the path as a breadcrumb: ancestor directories in quiet text,
    /// separated by chevrons, with the filename as the only emphasized run. A
    /// slash-joined string made the whole path read as one undifferentiated
    /// blob, so the file you actually have open was the hardest part to find.
    private func updatePathBar() {
        guard let url = fileURL else {
            pathBar.attributedStringValue = NSAttributedString(string: "")
            return
        }
        let ancestorFont = DesignTokens.Typography.rowSecondary.font
        let fileNameFont = NSFont.systemFont(
            ofSize: DesignTokens.Typography.rowSecondary.sizePT,
            weight: .medium
        )
        let value = NSMutableAttributedString()
        let ancestors = url.deletingLastPathComponent().pathComponents
            .filter { $0 != TerminalCodeEditorConstants.rootPathComponent }
        for ancestor in ancestors {
            value.append(NSAttributedString(
                string: ancestor,
                attributes: [.foregroundColor: palette.mutedText, .font: ancestorFont]
            ))
            value.append(breadcrumbSeparator())
        }
        value.append(NSAttributedString(
            string: url.lastPathComponent,
            attributes: [.foregroundColor: palette.secondaryText, .font: fileNameFont]
        ))
        if dirtyTracker.isDirty {
            value.append(NSAttributedString(
                string: " " + TerminalCodeEditorConstants.modifiedDotGlyph,
                attributes: [.foregroundColor: palette.modifiedDot, .font: ancestorFont]
            ))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        value.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: value.length)
        )
        pathBar.attributedStringValue = value
    }

    /// A chevron with `x1` of air on both sides. Falls back to a plain glyph if
    /// the symbol is unavailable so the path never collapses into one word.
    private func breadcrumbSeparator() -> NSAttributedString {
        // A zero-width space carrying exactly `x1` of kerning: a literal space
        // would be whatever the system font decides, not a design step.
        let spacer = NSAttributedString(
            string: TerminalCodeEditorConstants.zeroWidthSpace,
            attributes: [
                .font: DesignTokens.Typography.rowSecondary.font,
                .kern: DesignTokens.Space.x1PX,
            ]
        )
        let separator = NSMutableAttributedString()
        separator.append(spacer)
        guard let image = Icon.symbol(
            IconSymbol.breadcrumbSeparator,
            pointSizePT: DesignTokens.Component.codeEditorBreadcrumbSeparatorPointSizePT,
            weight: .semibold,
            tint: palette.mutedText
        ) else {
            separator.append(NSAttributedString(
                string: TerminalCodeEditorConstants.breadcrumbSeparatorFallbackGlyph,
                attributes: [
                    .foregroundColor: palette.mutedText,
                    .font: DesignTokens.Typography.rowSecondary.font,
                ]
            ))
            separator.append(spacer)
            return separator
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: (DesignTokens.Typography.rowSecondary.font.capHeight - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height
        )
        separator.append(NSAttributedString(attachment: attachment))
        separator.append(spacer)
        return separator
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
        // No separate gutter tint: a differently colored strip beside the text
        // is a 2010 IDE idiom. The gutter shares the editor background and is
        // separated by a hairline only.
        palette.editorBackground.setFill()
        bounds.fill()
        palette.hairline.setFill()
        NSRect(
            x: bounds.maxX - DesignTokens.Component.hairlinePX,
            y: bounds.minY,
            width: DesignTokens.Component.hairlinePX,
            height: bounds.height
        ).fill()

        rebuildLineIndexIfNeeded(text: textView.string as NSString)
        let currentLine = lineNumber(forCharacterIndex: textView.selectedRange().location)
        let font = DesignTokens.Typography.monoGutter.font
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
            // The current line steps up one rank only; a full-contrast number
            // would out-shout the code it labels.
            .foregroundColor: emphasized ? palette.secondaryText : palette.mutedText,
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
    /// Path-bar fill. Raised, so the bar reads as a bar and not as text sitting
    /// loose on the editor background.
    let pathBarBackground: NSColor
    /// Single separation color for the path bar's bottom edge and the gutter's
    /// right edge.
    let hairline: NSColor
    let plainText: NSColor
    let primaryText: NSColor
    let secondaryText: NSColor
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
            pathBarBackground: theme.surfaceRaised,
            hairline: theme.hairline,
            plainText: theme.textPrimary,
            primaryText: theme.textPrimary,
            secondaryText: theme.textSecondary,
            mutedText: theme.textTertiary,
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
    /// Drawn when the SF Symbol breadcrumb chevron is unavailable.
    static let breadcrumbSeparatorFallbackGlyph = "\u{203A}"
    static let zeroWidthSpace = "\u{200B}"
    static let rootPathComponent = "/"
}

