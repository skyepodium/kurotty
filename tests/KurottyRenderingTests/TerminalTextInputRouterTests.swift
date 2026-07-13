import AppKit
import KurottyCore
import XCTest
@testable import KurottyApp

final class TerminalTextInputRouterTests: XCTestCase {
    @MainActor
    func testPromptInputViewMarkedTextIsOverlayOnlyUntilCommit() throws {
        let core = SpyTerminalCore()
        let view = TerminalInputView(core: core)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 96)

        view.setMarkedText("ㅇ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("아", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        view.setMarkedText("안", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))

        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(core.fedText, [])

        view.insertText("안", replacementRange: NSRange(location: 0, length: 1))

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(core.fedText, ["안"])
    }

    @MainActor
    func testPromptInputViewInvalidatesWhenMarkedTextStartsBeforeCommit() throws {
        let view = TerminalInputView(core: CoreBridge(cols: 80, rows: 24))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 96)

        view.setMarkedText("ㅇ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(view.hasMarkedText())

        let source = try terminalInputViewSource()
        let setMarkedTextStart = try XCTUnwrap(source.range(of: "func setMarkedText"))
        let unmarkTextStart = try XCTUnwrap(source.range(of: "func unmarkText"))
        let setMarkedTextSource = source[setMarkedTextStart.lowerBound..<unmarkTextStart.lowerBound]
        XCTAssertTrue(setMarkedTextSource.contains("requestTextInputRendererFrame()"))
    }

    func testTerminalSurfaceMarkedTextDoesNotSendToPtyOrCoreBeforeCommit() throws {
        let source = try terminalSurfaceViewSource()
        let setMarkedTextSource = try sourceSlice(
            in: source,
            from: "func setMarkedText",
            to: "func unmarkText"
        )
        let insertTextSource = try sourceSlice(
            in: source,
            from: "func insertText",
            to: "override func doCommand"
        )

        XCTAssertTrue(setMarkedTextSource.contains("markedText = NSMutableAttributedString(attributedString: attr)"))
        XCTAssertTrue(setMarkedTextSource.contains("inputSelectedRange = selectedRange"))
        XCTAssertTrue(setMarkedTextSource.contains("requestTextInputRendererFrame()"))
        XCTAssertFalse(setMarkedTextSource.contains("updateRendererFrame()"))
        XCTAssertFalse(setMarkedTextSource.contains("send("))
        XCTAssertFalse(setMarkedTextSource.contains("shell.write"))
        XCTAssertFalse(setMarkedTextSource.contains("core.feed"))

        XCTAssertTrue(insertTextSource.contains("clearMarkedText(renderFrame: false)"))
        XCTAssertTrue(insertTextSource.contains("guard !text.isEmpty else { return }"))
        XCTAssertTrue(insertTextSource.contains("sendCommittedText(text, source: \"insertText\")"))
    }

    func testTerminalSurfaceCommitDoesNotRenderBlankMarkedTextFrameBeforeEcho() throws {
        let source = try terminalSurfaceViewSource()
        let insertTextSource = try sourceSlice(
            in: source,
            from: "func insertText",
            to: "override func doCommand"
        )

        XCTAssertFalse(insertTextSource.contains("clearMarkedText(renderFrame: shouldRenderClearFrame)"))
        XCTAssertTrue(insertTextSource.contains("clearMarkedText(renderFrame: false)"))
    }

    func testTerminalSurfaceKeepsCommittedIMEPrefixVisibleUntilEchoWhenCompositionContinues() throws {
        let source = try terminalSurfaceViewSource()
        let insertTextSource = try sourceSlice(
            in: source,
            from: "func insertText",
            to: "override func doCommand"
        )
        let frameSource = try sourceSlice(
            in: source,
            from: "private func updateRendererFrame()",
            to: "private func renderedMarkedTextPosition"
        )
        let outputSource = try sourceSlice(
            in: source,
            from: "private func appendOutput(_ text: String)",
            to: "private func beginOutputRuntimeEventBatch"
        )

        XCTAssertTrue(source.contains("private var committedMarkedTextPrefix = \"\""))
        XCTAssertTrue(source.contains("private var committedMarkedTextPrefixAnchor: TerminalCellPosition?"))
        XCTAssertTrue(insertTextSource.contains("appendCommittedMarkedTextPrefix(text)"))
        XCTAssertTrue(frameSource.contains("let compositionText = textInputOverlayText()"))
        XCTAssertTrue(source.contains("guard !committedMarkedTextPrefix.isEmpty else"))
        XCTAssertFalse(source.contains("guard hasMarkedText() else {\n            return markedText.string\n        }"))
        XCTAssertTrue(frameSource.contains("markedTextSelectedRange: markedTextSelectionRange(committedPrefix: committedMarkedTextPrefix)"))
        XCTAssertTrue(outputSource.contains("clearCommittedMarkedTextPrefix()"))
    }

    func testPromptInputViewCommitDoesNotRenderBlankMarkedTextFrameBeforeEcho() throws {
        let source = try terminalInputViewSource()
        let insertTextSource = try sourceSlice(
            in: source,
            from: "func insertText",
            to: "override func doCommand"
        )

        XCTAssertTrue(insertTextSource.contains("clearMarkedText(renderFrame: false)"))
        XCTAssertFalse(insertTextSource.contains("shouldRenderClearFrame"))
    }

    func testCJKGlyphsKeepTerminalCellWidthWithoutStretchingBitmap() throws {
        let source = try terminalMetalViewSource()
        let appendGlyphSource = try sourceSlice(
            in: source,
            from: "private func appendGlyphInstance",
            to: "private func diagnosticDirtyRectPixels"
        )

        XCTAssertTrue(source.contains("Self.isCJKGlyph(character)"))
        XCTAssertTrue(source.contains("cellWidthPixels: canonicalMetrics.cellWidthPixels * columnWidth"))
        XCTAssertTrue(appendGlyphSource.contains("width: CGFloat(pixelSize.width)"))
        XCTAssertTrue(appendGlyphSource.contains("size: SIMD2<Float>(Float(pixelSize.width), Float(pixelSize.height))"))
        XCTAssertFalse(source.contains("glyphRenderPixelWidth(for character: Character, entry: GlyphAtlasEntry)"))
        XCTAssertFalse(source.contains("max(entry.pixelSize.width, entry.cellWidthPixels)"))
    }

    func testPromptInputViewNewlineCommandUsesTerminalKeyEncoder() throws {
        let source = try terminalInputViewSource()
        let doCommandStart = try XCTUnwrap(source.range(of: "override func doCommand"))
        let setMarkedTextStart = try XCTUnwrap(source.range(of: "func setMarkedText"))
        let doCommandSource = source[doCommandStart.lowerBound..<setMarkedTextStart.lowerBound]
        let encoderSource = try terminalKeyEncoderSource()

        XCTAssertTrue(doCommandSource.contains("TerminalKeyEncoder.sequence(for: selector)"))
        XCTAssertTrue(doCommandSource.contains("flushAccumulatedCommittedText()"))
        XCTAssertTrue(encoderSource.contains("case #selector(NSResponder.insertNewline(_:)):\n            return \"\\r\""))
        XCTAssertFalse(encoderSource.contains("case #selector(NSResponder.insertNewline(_:)):\n            return \"\\n\""))
    }

    func testCommittedIMETextFlushesBeforeTerminalCommand() throws {
        let surfaceSource = try terminalSurfaceViewSource()
        let inputSource = try terminalInputViewSource()

        let surfaceDoCommandSource = try sourceSlice(
            in: surfaceSource,
            from: "override func doCommand",
            to: "func setMarkedText"
        )
        let inputDoCommandSource = try sourceSlice(
            in: inputSource,
            from: "override func doCommand",
            to: "func setMarkedText"
        )

        let surfaceFlush = try XCTUnwrap(surfaceDoCommandSource.range(of: "flushAccumulatedCommittedText()"))
        let surfaceSend = try XCTUnwrap(surfaceDoCommandSource.range(of: "send(sequence)"))
        XCTAssertLessThan(surfaceFlush.lowerBound, surfaceSend.lowerBound)

        let inputFlush = try XCTUnwrap(inputDoCommandSource.range(of: "flushAccumulatedCommittedText()"))
        let inputFeed = try XCTUnwrap(inputDoCommandSource.range(of: "core.feed(sequence)"))
        XCTAssertLessThan(inputFlush.lowerBound, inputFeed.lowerBound)

        XCTAssertTrue(surfaceSource.contains("private func flushAccumulatedCommittedText() -> Bool"))
        XCTAssertTrue(inputSource.contains("private func flushAccumulatedCommittedText() -> Bool"))
    }

    func testReturnUsesTerminalEnterAction() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\r")
    }

    func testShiftReturnUsesLineFeedInsteadOfTerminalEnterAction() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\n")
    }

    @MainActor
    func testShiftReturnBypassesTextInputContextWhenNoCompositionIsActive() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        XCTAssertFalse(TerminalTextInputRouter.handleKeyDown(event, in: NSView(), hasMarkedText: false))
    }

    @MainActor
    func testCapsLockTabBypassesTextInputContextForTerminalCompletion() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .capsLock,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\t")
        XCTAssertFalse(TerminalTextInputRouter.handleKeyDown(event, in: NSView(), hasMarkedText: false))
    }

    @MainActor
    func testTabKeyWritesRawTabToTerminalSession() throws {
        for modifiers: NSEvent.ModifierFlags in [[], .capsLock] {
            let session = RecordingTerminalSession()
            let surface = TerminalSurfaceView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 480),
                session: session
            )
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: 48
            ))

            surface.keyDown(with: event)

            XCTAssertEqual(session.writes, ["\t"])
        }
    }

    @MainActor
    func testPlainTextKeyWithHiddenCharactersStillUsesTextInputContext() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 2
        ))

        XCTAssertTrue(TerminalTextInputRouter.handleKeyDown(event, in: NSView(), hasMarkedText: false))
    }

    @MainActor
    func testShiftArrowsBypassTextInputContextWhenNoCompositionIsActive() throws {
        let arrowEvents: [(keyCode: UInt16, functionKey: unichar)] = [
            (keyCode: 123, functionKey: unichar(NSLeftArrowFunctionKey)),
            (keyCode: 124, functionKey: unichar(NSRightArrowFunctionKey)),
            (keyCode: 125, functionKey: unichar(NSDownArrowFunctionKey)),
            (keyCode: 126, functionKey: unichar(NSUpArrowFunctionKey)),
        ]

        for arrowEvent in arrowEvents {
            let characters = String(UnicodeScalar(arrowEvent.functionKey)!)
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.shift, .numericPad],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: arrowEvent.keyCode
            ))

            XCTAssertFalse(TerminalTextInputRouter.handleKeyDown(event, in: NSView(), hasMarkedText: false))
        }
    }

    func testKeypadEnterUsesTerminalEnterActionWithNumericPadFlag() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .numericPad,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 76
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\r")
    }

    func testControlBUsesKeyCodeFallbackWhenCharactersAreMissing() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 11
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\u{2}")
    }

    func testControlBStillUsesCharacterPathWhenCharactersAreAvailable() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{2}",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\u{2}")
    }

    func testControlUUsesKeyCodeFallbackWhenInputSourceHidesCharacters() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 32
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\u{15}")
    }

    func testCommandUUsesTerminalControlFallbackUnderNonEnglishInputSource() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 32
        ))

        XCTAssertEqual(TerminalTextInputRouter.latinKeyEquivalent(for: event), "u")
        XCTAssertEqual(TerminalTextInputRouter.commandShortcutControlText(for: event), "\u{15}")
    }

    func testCommandControlFallbackIgnoresCapsLockState() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.capsLock, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 32
        ))

        XCTAssertEqual(TerminalTextInputRouter.commandShortcutControlText(for: event), "\u{15}")
    }

    func testCommandShortcutFallbackDoesNotRunForOptionChords() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 32
        ))

        XCTAssertNil(TerminalTextInputRouter.commandShortcutControlText(for: event))
    }

    func testControlKeyFallbackDoesNotRunForCommandOrOptionChords() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 11
        ))

        XCTAssertNil(TerminalTextInputRouter.terminalControlText(for: event))
    }

    func testControlCUsesKeyCodeFallbackWhenCharactersAreMissing() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 8
        ))

        XCTAssertEqual(TerminalTextInputRouter.terminalControlText(for: event), "\u{3}")
    }

    private func terminalInputViewSource() throws -> String {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/KurottyApp/TerminalInputView.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func terminalSurfaceViewSource() throws -> String {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/KurottyApp/TerminalSurfaceView.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func terminalMetalViewSource() throws -> String {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/KurottyApp/TerminalMetalView.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func terminalKeyEncoderSource() throws -> String {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/KurottyApp/TerminalKeyEncoder.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func sourceSlice(in source: String, from startPattern: String, to endPattern: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: startPattern))
        let end = try XCTUnwrap(source.range(of: endPattern, range: start.upperBound..<source.endIndex))
        return source[start.lowerBound..<end.lowerBound]
    }
}

private final class SpyTerminalCore: TerminalCore {
    private(set) var fedText: [String] = []

    func feed(_ text: String) {
        fedText.append(text)
    }

    func recordKeyEvent() {}
    func recordFramePresented() {}
    func beginFrame(visibleCells: UInt32) -> UInt32 { 0 }
    func endFrame() {}
    func lastLatencyMicros() -> UInt64 { 0 }
    func resize(cols: UInt32, rows: UInt32) {}
    func cell(row: UInt32, col: UInt32) -> UInt8 { 0 }
    func copyRow(_ row: UInt32, into buffer: inout [UInt8]) -> Int { 0 }
}

private final class RecordingTerminalSession: TerminalSession {
    var onOutput: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
    var onExit: ((Int32) -> Void)?
    private(set) var writes: [String] = []

    func start(workingDirectory requestedWorkingDirectory: String) {}
    func write(_ text: String) { writes.append(text) }
    func foregroundProcessName() -> String? { "ssh" }
    func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
    func resize(columns: Int, rows: Int) {}
    func stop() {}
}
