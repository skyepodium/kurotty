import AppKit
import KurottyCore

/// Side effects the output interpreter needs from its hosting surface view.
/// The interpreter owns parser and screen-model state; anything that touches
/// the shell, AppKit, notifications, geometry, or focus goes through here.
@MainActor
struct TerminalOutputInterpreterHost {
    let sendTerminalResponse: (String) -> Void
    let respondToOscQuery: (String) -> Void
    let dispatchTerminalIntegrationOsc: (String) -> TerminalOSCDispatcher.Event
    let publishTitle: () -> Void
    let handleTerminalIntegrationEvent: (TerminalOSCDispatcher.Event) -> Void
    let handleDesktopNotificationEvent: (TerminalOSCDispatcher.Event) -> Void
    let handleClipboardWriteEvent: (TerminalOSCDispatcher.Event) -> Void
    let ringTerminalBell: () -> Void
    let updateScrollIndicator: () -> Void
    let maxScrollbackOffset: (_ visibleRows: Int?) -> Int
    let reportTerminalFocusIfNeeded: () -> Void
    /// Live cell/grid geometry from the renderer's single metrics path. `nil`
    /// while the surface has no usable size yet, which suppresses the pixel
    /// capability replies rather than inventing a second source of truth.
    let terminalCapabilityMetrics: () -> TerminalCapabilityMetrics?
    /// The terminal's current color scheme, used by DEC mode 2031 replies.
    let terminalColorSchemeMode: () -> TerminalColorSchemeMode
}

/// VT parser and screen-mutation engine extracted from TerminalSurfaceView.
/// Everything between "bytes in" and "TerminalScreen + scrollback mutated +
/// dirty rows marked" lives here; the surface view keeps NSView/input/IME,
/// selection, search, renderer frame building, and shell/tmux wiring.
@MainActor
final class TerminalOutputInterpreter {
    var host: TerminalOutputInterpreterHost?

    var terminalDefaultStyle: TerminalTextStyle
    var terminalAnsiColors: [SIMD4<Float>]
    var maxScrollbackRows: Int
    var screen = TerminalScreen(rows: AppConstants.Terminal.defaultRows, columns: AppConstants.Terminal.defaultColumns)
    var scrollbackRows = BoundedScrollbackRows()
    var scrollbackOffset = 0
    var normalScreenSnapshot: TerminalScreen?
    var cursorRow = 0
    var cursorColumn = 0
    private var savedCursorRow = 0
    private var savedCursorColumn = 0
    private var alternateSavedCursorRow = 0
    private var alternateSavedCursorColumn = 0
    var scrollRegionTop = 0
    var scrollRegionBottom = AppConstants.Terminal.defaultRows - 1
    var cursorVisible = true
    var isUsingAlternateScreen = false
    private var alternateScreenRestoresCursor = false
    var insertModeEnabled = false
    var originModeEnabled = false
    var wraparoundModeEnabled = true
    var applicationCursorKeysEnabled = false
    var applicationKeypadEnabled = false
    var modifyOtherKeysMode = 0
    var extendedKeyFormat: TerminalExtendedKeyFormat = .xterm
    var tabStops = Set(stride(from: 8, through: 992, by: 8))
    var bracketedPasteEnabled = false
    /// DEC private mode 2031. While enabled, an appearance change pushes a
    /// color-scheme notification so subscribed TUIs can re-theme live.
    var colorSchemeUpdateModeEnabled = false
    /// While true, every terminal reply is suppressed. Persisted scrollback
    /// being replayed into the interpreter can contain the *old* session's
    /// capability queries; answering those would inject stray bytes into the
    /// fresh shell's stdin. The replay path owns this flag and must clear it
    /// once live PTY output resumes.
    var isReplayingScrollback = false
    var mouseReportingState = TerminalMouseReportingState()
    var focusReportingState = TerminalFocusReportingState()
    var pressedMouseButton: TerminalMouseButton?
    var currentStyle: TerminalTextStyle
    var activeHyperlinkURL: String?
    private var parserState = StreamState.normal
    private var csiBuffer = ""
    private var oscBuffer = ""
    var terminalTitle = "-zsh"
    var currentWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    /// `user@host` when the shell reported an OSC 7 directory on another
    /// machine. `nil` means the directory is on this Mac, which is also the
    /// state before any OSC 7 arrives.
    var currentWorkingDirectoryRemoteHost: String?
    /// Combined view for panels that must decide whether local filesystem work
    /// is meaningful at all.
    var currentWorkingDirectoryLocation: TerminalWorkingDirectoryLocation {
        TerminalWorkingDirectoryLocation(
            path: currentWorkingDirectory,
            remoteHost: currentWorkingDirectoryRemoteHost
        )
    }
    var shellIntegration = TerminalShellIntegration(
        currentWorkingDirectoryCandidate: FileManager.default.homeDirectoryForCurrentUser.path
    )
    var lastSentSize = TerminalSize(columns: AppConstants.Terminal.defaultColumns, rows: AppConstants.Terminal.defaultRows)
    var pendingDirtyRows = Set<Int>()
    var pendingFullDamage = true
    var scrollbackRowsAppendedDuringOutput = 0

    init(defaultStyle: TerminalTextStyle, ansiColors: [SIMD4<Float>], maxScrollbackRows: Int) {
        terminalDefaultStyle = defaultStyle
        terminalAnsiColors = ansiColors
        self.maxScrollbackRows = maxScrollbackRows
        currentStyle = defaultStyle
    }

    func interpret(_ text: String) {
        for character in text {
            if parserState == .normal && character.isTerminalPrintableGrapheme {
                appendPrintable(String(character))
                continue
            }

            // Anything that is not printable text ends the syllable that was
            // open: a control byte, an escape, a CSI parameter. Whatever cell
            // the jamo landed in is finished, so a trailing consonant arriving
            // after this belongs to no syllable and stays its own cell.
            pendingHangulSyllable = nil

            for scalar in character.unicodeScalars {
                if consumeControl(scalar) {
                    continue
                }

                switch scalar.value {
                case 10:
                    lineFeed()
                case 13:
                    cursorColumn = 0
                case 8:
                    cursorColumn = max(0, cursorColumn - 1)
                case 9:
                    horizontalTab()
                case 7:
                    ringTerminalBell()
                case 0..<32, 127:
                    continue
                default:
                    appendPrintable(String(Character(scalar)))
                }
            }
        }
    }

    private func appendPrintable(_ text: String) {
        for character in text {
            if let extended = hangulSyllableExtended(by: character) {
                writeHangulSyllable(extended)
                continue
            }

            // Composed before the width is read, so the cell holds the
            // precomposed syllable a Korean user expects to copy, serialize and
            // search for rather than the NFD jamo the filesystem handed out.
            let printable = TerminalHangulComposition.composed(character)
            let arrivedAsJamo = TerminalHangulComposition.isConjoiningJamoCluster(character)
            let width = printable.terminalColumnWidth
            guard width > 0 else {
                pendingHangulSyllable = nil
                screen.appendCombining(character: character, row: cursorRow, before: cursorColumn)
                markDirty(row: cursorRow)
                continue
            }
            if wraparoundModeEnabled {
                if width == 2 && cursorColumn == screen.columns - 1 {
                    screen.markRowWrapped(cursorRow)
                    carriageReturnLineFeed()
                } else if cursorColumn >= screen.columns {
                    screen.markRowWrapped(cursorRow)
                    carriageReturnLineFeed()
                }
            } else {
                cursorColumn = min(max(0, cursorColumn), max(0, screen.columns - 1))
            }

            if insertModeEnabled {
                screen.insertCharacters(
                    row: cursorRow,
                    column: cursorColumn,
                    count: min(width, screen.columns - cursorColumn),
                    style: currentStyle
                )
            }

            let writtenRow = cursorRow
            let writtenColumn = cursorColumn
            screen.set(
                character: printable,
                row: writtenRow,
                column: writtenColumn,
                width: width,
                style: currentStyle,
                linkURL: activeHyperlinkURL
            )
            markDirty(row: writtenRow)
            if wraparoundModeEnabled {
                cursorColumn += width
            } else {
                cursorColumn = min(screen.columns - 1, cursorColumn + width)
            }

            pendingHangulSyllable = arrivedAsJamo
                ? PendingHangulSyllable(
                    row: writtenRow,
                    column: writtenColumn,
                    width: width,
                    character: printable,
                    style: currentStyle,
                    linkURL: activeHyperlinkURL
                )
                : nil
        }
    }

    // MARK: - Hangul syllable composition

    /// A syllable already written to a cell that a later jamo may still extend.
    ///
    /// WHY the cell is rewritten rather than the syllable buffered: the jamo of
    /// one syllable can be split across PTY chunks, so a `ᄀ` can arrive in one
    /// `interpret` call and its `ᅡ`/`ᆨ` in the next. Buffering the incomplete
    /// syllable until the next character would hold it back indefinitely —
    /// there is no flush signal, and a prompt or a `read -p` ending in Korean
    /// would sit on screen with its last syllable missing until the user typed
    /// something. Writing immediately and replacing the cell in place keeps
    /// output latency identical to every other character and converges on the
    /// same grid, at the cost of one extra dirty mark on the row that was going
    /// to be redrawn anyway.
    ///
    /// Only a write that *arrived* as conjoining jamo becomes pending. A program
    /// that printed a precomposed `가` and later, separately, a lone `ᆨ` meant
    /// two things, and merging them would corrupt its output; decomposed text
    /// never contains a precomposed syllable, so this loses no real case.
    private struct PendingHangulSyllable {
        let row: Int
        let column: Int
        let width: Int
        let character: Character
        let style: TerminalTextStyle
        let linkURL: String?
    }

    private var pendingHangulSyllable: PendingHangulSyllable?

    /// The pending syllable grown by `character`, or `nil` when `character` does
    /// not continue it. The cursor and the cell contents are both re-checked:
    /// the cursor must still sit immediately after the pending cell, and that
    /// cell must still hold what was written there, so any intervening cursor
    /// move, erase, scroll, resize or overwrite drops the merge instead of
    /// rewriting a cell that now belongs to something else.
    private func hangulSyllableExtended(by character: Character) -> PendingHangulSyllable? {
        guard let pending = pendingHangulSyllable,
              TerminalHangulComposition.isSyllableContinuationCluster(character),
              cursorRow == pending.row,
              cursorColumn == pending.column + pending.width,
              screen.cells.indices.contains(pending.row),
              screen.cells[pending.row].indices.contains(pending.column),
              screen.cells[pending.row][pending.column].character == pending.character,
              let composed = TerminalHangulComposition.merging(pending.character, with: character)
        else {
            return nil
        }
        return PendingHangulSyllable(
            row: pending.row,
            column: pending.column,
            width: composed.terminalColumnWidth,
            character: composed,
            style: pending.style,
            linkURL: pending.linkURL
        )
    }

    private func writeHangulSyllable(_ syllable: PendingHangulSyllable) {
        screen.set(
            character: syllable.character,
            row: syllable.row,
            column: syllable.column,
            width: syllable.width,
            style: syllable.style,
            linkURL: syllable.linkURL
        )
        markDirty(row: syllable.row)
        // The syllable occupies the same columns it did before the merge, so
        // the cursor lands where it already was. Recomputing it keeps the two
        // in step if a jamo ever changes the composed width.
        cursorColumn = wraparoundModeEnabled
            ? syllable.column + syllable.width
            : min(screen.columns - 1, syllable.column + syllable.width)
        pendingHangulSyllable = syllable
    }

    private func lineFeed() {
        markDirty(row: cursorRow)
        if cursorRow >= scrollRegionTop && cursorRow == scrollRegionBottom {
            let removed = screen.scrollUpRegion(top: scrollRegionTop, bottom: scrollRegionBottom, style: currentStyle)
            if shouldAppendScrollbackForActiveScrollRegion() {
                appendScrollback(rows: removed)
            }
            markFullDamage()
        } else {
            cursorRow = min(screen.rows - 1, cursorRow + 1)
            markDirty(row: cursorRow)
        }
    }

    func resetScrollRegion() {
        scrollRegionTop = 0
        scrollRegionBottom = max(0, screen.rows - 1)
        logScrollRegion(reason: "reset")
    }

    private func setScrollRegion(_ parsed: CsiParameters) {
        guard !parsed.isPrivate else { return }
        if parsed.values.isEmpty {
            resetScrollRegion()
        } else {
            let top = max(0, min(screen.rows - 1, parsed.value(at: 0, default: 1) - 1))
            let bottom = max(0, min(screen.rows - 1, parsed.value(at: 1, default: screen.rows) - 1))
            guard top < bottom else { return }
            scrollRegionTop = top
            scrollRegionBottom = bottom
            logScrollRegion(reason: "set")
        }
        // DECSTBM moves the cursor home so subsequent TUI draws target the new
        // scroll contract rather than the old cursor row.
        cursorRow = originModeEnabled ? scrollRegionTop : 0
        cursorColumn = 0
        markFullDamage()
    }

    private func logScrollRegion(reason: String) {
        guard DebugOptions.scrollRegion || DebugOptions.vtParser else { return }
        NSLog(
            "Kurotty scroll region %@: top=%d bottom=%d rows=%d cursor=(%d,%d)",
            reason,
            scrollRegionTop,
            scrollRegionBottom,
            screen.rows,
            cursorRow,
            cursorColumn
        )
    }

    private func appendScrollback(rows: [[TerminalScreenCell]]) {
        scrollbackRowsAppendedDuringOutput += rows.count
        scrollbackRows.append(contentsOf: rows, limit: maxScrollbackRows)
        scrollbackOffset = min(scrollbackOffset, maxScrollbackOffset())
        updateScrollIndicator()
    }

    @discardableResult
    func trimScrollbackRowsToLimit() -> Bool {
        let didTrim = scrollbackRows.trim(to: maxScrollbackRows)
        scrollbackOffset = min(scrollbackOffset, maxScrollbackOffset())
        return didTrim
    }

    private func shouldAppendScrollbackForActiveScrollRegion() -> Bool {
        // TUIs such as Codex often reserve bottom rows with DECSTBM while still
        // scrolling the transcript from row 0. Lines leaving that top-anchored
        // region should remain reachable via terminal scrollback.
        scrollRegionTop == 0
    }

    private func carriageReturnLineFeed() {
        cursorColumn = 0
        lineFeed()
    }

    /// HT advances to the next tab stop but never past the last column.
    ///
    /// `tabStops` holds every multiple of 8 up to 992 regardless of the current
    /// width, so an unclamped "next stop" lands outside the screen on any
    /// narrower pane — three tabs on a 20-column screen reached column 24, and
    /// the CPR issued there reported a column that does not exist.
    ///
    /// The VT510 programmer reference is explicit: "Moves the cursor to the
    /// next tab stop. If there are no more tab stops, the cursor moves to the
    /// right margin. HT does not cause text to auto wrap." xterm implements
    /// exactly that in `tabs.c`'s `TabToNextStop` (`if (next > max) next =
    /// max;` where `max` is `max_col`, the last column), as do ghostty and
    /// kitty.
    private func horizontalTab() {
        let lastColumn = max(0, screen.columns - 1)
        let nextStop = tabStops.filter { $0 > cursorColumn }.min() ?? lastColumn
        cursorColumn = min(nextStop, lastColumn)
    }

    private func consumeControl(_ scalar: UnicodeScalar) -> Bool {
        switch parserState {
        case .normal:
            if scalar.value == 0x1b {
                parserState = .escape
                return true
            }
            return false
        case .escape:
            switch scalar {
            case "[":
                csiBuffer = ""
                parserState = .csi
            case "]":
                oscBuffer = ""
                parserState = .osc
            case "P", "X", "^", "_":
                // DCS, SOS, PM, APC (ECMA-48 §8.3.27, §8.3.128, §8.3.94,
                // §8.3.2). Their payloads are addressed to the terminal, not
                // the screen, so they are consumed to their string terminator
                // and dropped — the same "ignored" xterm gives SOS, PM and APC.
                // Nothing here is parsed: answering DECRQSS would be a new
                // feature, whereas the bug is that a DECRQSS probe
                // (`ESC P 1 $ r ... ESC \`) or a Kitty graphics envelope
                // (`ESC _ G ... ESC \`) painted its whole payload as text.
                parserState = .stringControl
            case let scalar where TerminalEscapeSequence.beginsTwoByteDesignator(scalar):
                parserState = .escapeDesignator
            case let scalar where TerminalEscapeSequence.beginsTwoByteDecPrivate(scalar):
                parserState = .escapeDecPrivate
            case "7":
                savedCursorRow = cursorRow
                savedCursorColumn = cursorColumn
                parserState = .normal
            case "8":
                cursorRow = min(screen.rows - 1, savedCursorRow)
                cursorColumn = min(screen.columns - 1, savedCursorColumn)
                parserState = .normal
            case "H":
                tabStops.insert(cursorColumn)
                parserState = .normal
            case "=":
                applicationKeypadEnabled = true
                parserState = .normal
            case ">":
                applicationKeypadEnabled = false
                parserState = .normal
            case "D":
                lineFeed()
                parserState = .normal
            case "E":
                carriageReturnLineFeed()
                parserState = .normal
            case "M":
                reverseIndex()
                parserState = .normal
            case "c":
                resetTerminal()
                parserState = .normal
            default:
                parserState = .normal
            }
            return true
        case .escapeDesignator:
            parserState = .normal
            return true
        case .escapeDecPrivate:
            parserState = .normal
            return true
        case .csi:
            if isCsiFinal(scalar) {
                executeCsi(final: Character(scalar), params: csiBuffer)
                csiBuffer = ""
                parserState = .normal
            } else if csiBuffer.utf8.count >= AppConstants.Terminal.maximumCsiParameterBytes {
                csiBuffer = ""
                parserState = .csiDiscard
            } else {
                csiBuffer.append(Character(scalar))
            }
            return true
        case .csiDiscard:
            if isCsiFinal(scalar) {
                parserState = .normal
            }
            return true
        case .osc:
            if scalar.value == 0x07 {
                finishOsc(dispatch: true)
            } else if scalar.value == 0x1b {
                parserState = .oscEscape
            } else if oscBuffer.utf8.count >= AppConstants.Terminal.maximumStringPayloadBytes {
                oscBuffer = ""
                parserState = .oscDiscard
            } else {
                oscBuffer.append(Character(scalar))
            }
            return true
        case .oscDiscard:
            if scalar.value == 0x07 {
                parserState = .normal
            } else if scalar.value == 0x1b {
                parserState = .oscDiscardEscape
            }
            return true
        case .oscEscape, .oscDiscardEscape:
            let payloadWasDropped = parserState == .oscDiscardEscape
            if scalar == "\\" {
                finishOsc(dispatch: !payloadWasDropped)
                return true
            }
            // An ESC that is not ST abandons the string rather than resuming
            // print mid-payload. That is xterm — only `esc_table['\\']` reaches
            // `do_osc`, every other byte leaves the accumulator unused — and
            // vte, whose `ST_ESC` dispatches on `\` alone. The byte after the
            // ESC still introduces whatever sequence it names, so it is
            // re-dispatched from the escape state instead of being swallowed:
            // `ESC ] 0 ; t ESC X …` drops the title and enters SOS, which is
            // where the remaining bytes belong. src/parser.zig instead keeps
            // the OSC open and folds the ESC into the payload; this follows
            // xterm because that is the terminal Kurotty claims to be in TERM.
            oscBuffer = ""
            parserState = .escape
            return consumeControl(scalar)
        case .stringControl:
            // ST only. BEL closes an OSC and nothing else: ECMA-48 §8.3.27 and
            // §8.3.94 close DCS and PM with ST, and xterm's `CASE_BELL` rings
            // the bell and keeps accumulating unless the string mode is OSC.
            // tmux's DCS passthrough is why this matters in practice — it wraps
            // whatever the inner program emitted, BEL-terminated OSCs included,
            // and treating that BEL as the end of the DCS would spray the rest
            // of the passthrough onto the screen.
            if scalar.value == 0x1b {
                parserState = .stringEscape
            }
            return true
        case .stringEscape:
            if scalar == "\\" {
                parserState = .normal
                return true
            }
            parserState = .escape
            return consumeControl(scalar)
        }
    }

    private func isCsiFinal(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0x40 && scalar.value <= 0x7e
    }

    private func finishOsc(dispatch: Bool) {
        if dispatch {
            executeOsc(oscBuffer)
        }
        oscBuffer = ""
        parserState = .normal
    }

    private func executeOsc(_ command: String) {
        let parts = command.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let code = String(parts[0])
        let payload = String(parts[1])

        if payload == "?" {
            respondToOscQuery(code)
            return
        }

        let terminalEvent = dispatchTerminalIntegrationOsc(command)

        switch code {
        case "0", "1", "2":
            terminalTitle = payload
            publishTitle()
        case "7":
            if case let .shellIntegration(.workingDirectoryChanged(location)) = terminalEvent {
                currentWorkingDirectory = location.path
                currentWorkingDirectoryRemoteHost = location.remoteHost
            }
            publishTitle()
        case "8":
            applyHyperlinkControl(payload)
        default:
            break
        }

        handleTerminalIntegrationEvent(terminalEvent)
        handleDesktopNotificationEvent(terminalEvent)
        handleClipboardWriteEvent(terminalEvent)
    }

    private func applyHyperlinkControl(_ payload: String) {
        switch TerminalHyperlinkControl.update(fromOSC8Payload: payload) {
        case .activate(let urlString):
            activeHyperlinkURL = urlString
        case .clear:
            activeHyperlinkURL = nil
        case .ignore:
            break
        }
    }

    private func executeCsi(final: Character, params: String) {
        let parsed = CsiParameters(params)
        let previousCursorRow = cursorRow
        logCsi(final: final, params: params, parsed: parsed, phase: "before")
        switch final {
        case "A":
            cursorRow = max(0, cursorRow - parsed.value(at: 0, default: 1))
        case "B", "e":
            cursorRow = min(screen.rows - 1, cursorRow + parsed.value(at: 0, default: 1))
        case "C", "a":
            cursorColumn = min(screen.columns - 1, cursorColumn + parsed.value(at: 0, default: 1))
        case "D":
            cursorColumn = max(0, cursorColumn - parsed.value(at: 0, default: 1))
        case "E":
            cursorRow = min(screen.rows - 1, cursorRow + parsed.value(at: 0, default: 1))
            cursorColumn = 0
        case "F":
            cursorRow = max(0, cursorRow - parsed.value(at: 0, default: 1))
            cursorColumn = 0
        case "G", "`":
            cursorColumn = min(screen.columns - 1, max(0, parsed.value(at: 0, default: 1) - 1))
        case "H":
            setCursorPosition(parsed)
        case "f":
            if parsed.prefix == ">" {
                applyExtendedKeyFormat(parsed)
            } else {
                setCursorPosition(parsed)
            }
        case "J":
            eraseInDisplay(mode: parsed.value(at: 0, default: 0))
        case "K":
            eraseInLine(mode: parsed.value(at: 0, default: 0))
        case "L":
            insertLines(count: parsed.value(at: 0, default: 1))
        case "M":
            deleteLines(count: parsed.value(at: 0, default: 1))
        case "P":
            screen.deleteCharacters(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1), style: currentStyle)
            markDirty(row: cursorRow)
        case "X":
            let count = max(1, parsed.value(at: 0, default: 1))
            screen.clear(row: cursorRow, from: cursorColumn, through: cursorColumn + count - 1, style: currentStyle)
            markDirty(row: cursorRow)
        case "@":
            screen.insertCharacters(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1), style: currentStyle)
            markDirty(row: cursorRow)
        case "b":
            let written = screen.repeatPrecedingGraphicCharacter(row: cursorRow, column: cursorColumn, count: parsed.value(at: 0, default: 1))
            if written > 0 {
                cursorColumn = min(screen.columns, cursorColumn + written)
                markDirty(row: cursorRow)
            }
        case "S":
            let removed = screen.scrollUpRegion(top: scrollRegionTop, bottom: scrollRegionBottom, count: parsed.value(at: 0, default: 1), style: currentStyle)
            if shouldAppendScrollbackForActiveScrollRegion() {
                appendScrollback(rows: removed)
            }
            markFullDamage()
        case "T":
            screen.scrollDownRegion(top: scrollRegionTop, bottom: scrollRegionBottom, count: parsed.value(at: 0, default: 1), style: currentStyle)
            markFullDamage()
        case "m":
            if parsed.prefix == ">" {
                applyModifyOtherKeysMode(parsed)
            } else if TerminalSgrPolicy.shouldApplySgr(for: parsed) {
                applySgr(parsed.elements)
            }
        case "r":
            setScrollRegion(parsed)
        case "g":
            guard !parsed.isPrivate else { break }
            switch parsed.value(at: 0, default: 0) {
            case 0:
                tabStops.remove(cursorColumn)
            case 3:
                tabStops.removeAll(keepingCapacity: true)
            default:
                break
            }
        case "s":
            savedCursorRow = cursorRow
            savedCursorColumn = cursorColumn
        case "u":
            guard !parsed.isPrivate else { break }
            cursorRow = min(screen.rows - 1, savedCursorRow)
            cursorColumn = min(screen.columns - 1, savedCursorColumn)
        case "n":
            if parsed.prefix == ">", parsed.values.first == 4 {
                modifyOtherKeysMode = 0
            } else if !parsed.isPrivate, parsed.value(at: 0, default: 0) == 6 {
                sendTerminalResponse(cursorPositionReport())
            }
        case "c":
            if let response = TerminalDeviceAttributes.response(for: parsed) {
                sendTerminalResponse(response)
            }
        case "t", "p":
            respondToCapabilityQuery(final: final, rawParameters: params, parsed: parsed)
        case "h":
            setMode(params: parsed, enabled: true)
        case "l":
            setMode(params: parsed, enabled: false)
        default:
            break
        }
        if cursorRow != previousCursorRow {
            markDirty(row: previousCursorRow)
            markDirty(row: cursorRow)
        }
        logCsi(final: final, params: params, parsed: parsed, phase: "after")
    }

    private func respondToCapabilityQuery(final: Character, rawParameters: String, parsed: CsiParameters) {
        guard let query = TerminalCapabilityReplies.query(
            final: final,
            rawParameters: rawParameters,
            parsed: parsed
        ) else {
            return
        }
        guard let reply = TerminalCapabilityReplies.reply(
            for: query,
            metrics: terminalCapabilityMetrics(),
            colorSchemeUpdateModeEnabled: colorSchemeUpdateModeEnabled
        ) else {
            return
        }
        sendTerminalResponse(reply)
    }

    private func logCsi(final: Character, params: String, parsed: CsiParameters, phase: String) {
        guard DebugOptions.vtParser || DebugOptions.cursorLog else { return }
        NSLog(
            "Kurotty CSI %@: ESC[%@%@ private=%@ values=%@ cursor=(%d,%d) scrollRegion=%d-%d fg=%@ bg=%@",
            phase,
            params,
            String(final),
            parsed.isPrivate ? "yes" : "no",
            parsed.values.map(String.init).joined(separator: ","),
            cursorRow,
            cursorColumn,
            scrollRegionTop,
            scrollRegionBottom,
            currentStyle.effectiveForeground.debugRGB,
            currentStyle.effectiveBackground.debugRGB
        )
    }

    private func setCursorPosition(_ params: CsiParameters) {
        guard params.prefix == nil else { return }
        let requestedRow = max(0, params.value(at: 0, default: 1) - 1)
        if originModeEnabled {
            cursorRow = min(scrollRegionBottom, scrollRegionTop + requestedRow)
        } else {
            cursorRow = min(screen.rows - 1, requestedRow)
        }
        cursorColumn = min(screen.columns - 1, max(0, params.value(at: 1, default: 1) - 1))
    }

    private func applyModifyOtherKeysMode(_ params: CsiParameters) {
        guard params.values.first == 4 else { return }
        let requested = params.values.count > 1 ? params.values[1] : 0
        guard (0...2).contains(requested) else { return }
        modifyOtherKeysMode = requested
    }

    private func applyExtendedKeyFormat(_ params: CsiParameters) {
        guard params.values.first == 4 else { return }
        let requested = params.values.count > 1 ? params.values[1] : 0
        switch requested {
        case 0:
            extendedKeyFormat = .xterm
        case 1:
            extendedKeyFormat = .csiU
        default:
            break
        }
    }

    private func insertLines(count: Int) {
        let bottom = cursorRow >= scrollRegionTop && cursorRow <= scrollRegionBottom ? scrollRegionBottom : screen.rows - 1
        screen.insertLines(at: cursorRow, bottom: bottom, count: count, style: currentStyle)
        markDirty(rows: cursorRow..<(bottom + 1))
    }

    private func deleteLines(count: Int) {
        let bottom = cursorRow >= scrollRegionTop && cursorRow <= scrollRegionBottom ? scrollRegionBottom : screen.rows - 1
        screen.deleteLines(at: cursorRow, bottom: bottom, count: count, style: currentStyle)
        markDirty(rows: cursorRow..<(bottom + 1))
    }

    private func cursorPositionReport() -> String {
        "\u{1b}[\(cursorRow + 1);\(cursorColumn + 1)R"
    }

    private func setMode(params: CsiParameters, enabled: Bool) {
        if !params.isPrivate {
            for value in params.values where value == 4 {
                insertModeEnabled = enabled
            }
            return
        }
        for value in params.values {
            switch value {
            case 1:
                applicationCursorKeysEnabled = enabled
            case 6:
                originModeEnabled = enabled
                cursorRow = enabled ? scrollRegionTop : 0
                cursorColumn = 0
            case 7:
                wraparoundModeEnabled = enabled
            case 25:
                cursorVisible = enabled
                markDirty(row: cursorRow)
            case 47, 1047:
                if enabled {
                    enterAlternateScreen(restoresCursor: false)
                } else {
                    leaveAlternateScreen(restoresCursor: false)
                }
            case 1048:
                if enabled {
                    savedCursorRow = cursorRow
                    savedCursorColumn = cursorColumn
                } else {
                    cursorRow = min(screen.rows - 1, savedCursorRow)
                    cursorColumn = min(screen.columns - 1, savedCursorColumn)
                }
            case 1049:
                if enabled {
                    enterAlternateScreen(restoresCursor: true)
                } else {
                    leaveAlternateScreen(restoresCursor: true)
                }
            case 2004:
                bracketedPasteEnabled = enabled
            case TerminalCapabilityReplies.colorSchemeUpdateMode:
                colorSchemeUpdateModeEnabled = enabled
            case 1004:
                focusReportingState.set(enabled: enabled)
                reportTerminalFocusIfNeeded()
            case 1000, 1002, 1003, 1005, 1006, 1007:
                mouseReportingState.set(decPrivateMode: value, enabled: enabled)
            default:
                break
            }
        }
    }

    private func eraseInLine(mode: Int) {
        switch mode {
        case 0:
            screen.clear(row: cursorRow, from: cursorColumn, through: screen.columns - 1, style: currentStyle)
            markDirty(row: cursorRow)
        case 1:
            screen.clear(row: cursorRow, from: 0, through: cursorColumn, style: currentStyle)
            markDirty(row: cursorRow)
        case 2:
            screen.clear(row: cursorRow, style: currentStyle)
            markDirty(row: cursorRow)
        default:
            break
        }
    }

    private func eraseInDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseInLine(mode: 0)
            if cursorRow + 1 < screen.rows {
                for row in (cursorRow + 1)..<screen.rows {
                    screen.clear(row: row, style: currentStyle)
                }
                markDirty(rows: (cursorRow + 1)..<screen.rows)
            }
        case 1:
            if cursorRow > 0 {
                for row in 0..<cursorRow {
                    screen.clear(row: row, style: currentStyle)
                }
                markDirty(rows: 0..<cursorRow)
            }
            eraseInLine(mode: 1)
        case 2:
            screen.clear(style: currentStyle)
            cursorRow = 0
            cursorColumn = 0
            markFullDamage()
        case 3:
            scrollbackRows = BoundedScrollbackRows()
            scrollbackOffset = 0
            updateScrollIndicator()
            markFullDamage()
        default:
            break
        }
    }

    private func reverseIndex() {
        markDirty(row: cursorRow)
        if cursorRow >= scrollRegionTop && cursorRow == scrollRegionTop {
            screen.scrollDownRegion(top: scrollRegionTop, bottom: scrollRegionBottom, style: currentStyle)
            markFullDamage()
        } else {
            cursorRow = max(0, cursorRow - 1)
            markDirty(row: cursorRow)
        }
    }

    private func enterAlternateScreen(restoresCursor: Bool) {
        guard !isUsingAlternateScreen else { return }
        if restoresCursor {
            alternateSavedCursorRow = cursorRow
            alternateSavedCursorColumn = cursorColumn
        }
        normalScreenSnapshot = screen
        screen.clear()
        cursorRow = 0
        cursorColumn = 0
        resetScrollRegion()
        isUsingAlternateScreen = true
        alternateScreenRestoresCursor = restoresCursor
        markFullDamage()
    }

    private func leaveAlternateScreen(restoresCursor: Bool) {
        guard isUsingAlternateScreen else { return }
        let shouldRestoreCursor = restoresCursor || alternateScreenRestoresCursor
        if let snapshot = normalScreenSnapshot {
            screen = snapshot
            cursorRow = screen.resize(
                rows: lastSentSize.rows,
                columns: lastSentSize.columns,
                anchorRow: shouldRestoreCursor ? alternateSavedCursorRow : cursorRow
            )
        } else {
            screen.clear()
        }
        if shouldRestoreCursor {
            cursorRow = min(max(0, alternateSavedCursorRow), screen.rows - 1)
            cursorColumn = min(max(0, alternateSavedCursorColumn), screen.columns - 1)
        } else {
            cursorRow = min(cursorRow, screen.rows - 1)
            cursorColumn = min(cursorColumn, screen.columns - 1)
        }
        resetScrollRegion()
        normalScreenSnapshot = nil
        isUsingAlternateScreen = false
        alternateScreenRestoresCursor = false
        markFullDamage()
    }

    private func resetTerminal() {
        screen.clear()
        cursorRow = 0
        cursorColumn = 0
        cursorVisible = true
        insertModeEnabled = false
        originModeEnabled = false
        wraparoundModeEnabled = true
        applicationCursorKeysEnabled = false
        applicationKeypadEnabled = false
        modifyOtherKeysMode = 0
        extendedKeyFormat = .xterm
        tabStops = Set(stride(from: 8, through: 992, by: 8))
        bracketedPasteEnabled = false
        colorSchemeUpdateModeEnabled = false
        mouseReportingState.reset()
        focusReportingState.set(enabled: false)
        pressedMouseButton = nil
        currentStyle = terminalDefaultStyle
        activeHyperlinkURL = nil
        normalScreenSnapshot = nil
        isUsingAlternateScreen = false
        alternateScreenRestoresCursor = false
        resetScrollRegion()
        markFullDamage()
    }

    func markDirty(row: Int) {
        guard row >= 0 else { return }
        pendingDirtyRows.insert(row)
    }

    func markDirty(rows: Range<Int>) {
        for row in rows {
            markDirty(row: row)
        }
    }

    func markFullDamage() {
        pendingFullDamage = true
    }

    private func applySgr(_ elements: [CsiParameterElement]) {
        let codes = elements.isEmpty ? [CsiParameterElement(values: [0])] : elements
        var index = 0
        while index < codes.count {
            let element = codes[index]
            let code = element.value
            switch code {
            case 0:
                currentStyle = terminalDefaultStyle
            case 1:
                currentStyle.bold = true
            case 2:
                currentStyle.dim = true
            case 3:
                currentStyle.italic = true
            case 4:
                applyUnderlineSgr(element)
            case 5:
                currentStyle.blink = true
            case 9:
                currentStyle.strikethrough = true
            case 22:
                currentStyle.bold = false
                currentStyle.dim = false
            case 23:
                currentStyle.italic = false
            case 24:
                currentStyle.underline = false
            case 25:
                currentStyle.blink = false
            case 29:
                currentStyle.strikethrough = false
            case 7:
                currentStyle.inverse = true
            case 27:
                currentStyle.inverse = false
            case 30...37:
                currentStyle.foreground = terminalAnsiColor(code - 30, bright: currentStyle.bold)
                currentStyle.foregroundSource = .ansi
            case 39:
                currentStyle.foreground = terminalDefaultStyle.foreground
                currentStyle.foregroundSource = .defaultColor
            case 40...47:
                currentStyle.background = terminalAnsiColor(code - 40, bright: false)
                currentStyle.backgroundSource = .ansi
            case 49:
                currentStyle.background = terminalDefaultStyle.background
                currentStyle.backgroundSource = .defaultColor
            case 90...97:
                currentStyle.foreground = terminalAnsiColor(code - 90, bright: true)
                currentStyle.foregroundSource = .ansi
            case 100...107:
                currentStyle.background = terminalAnsiColor(code - 100, bright: true)
                currentStyle.backgroundSource = .ansi
            case 38, 48:
                let isForeground = code == 38
                if let resolved = colorFromColonSgr(element) {
                    if isForeground {
                        currentStyle.foreground = resolved.color
                        currentStyle.foregroundSource = resolved.source
                    } else {
                        currentStyle.background = resolved.color
                        currentStyle.backgroundSource = resolved.source
                    }
                    break
                }
                guard index + 1 < codes.count else { break }
                if codes[index + 1].value == 5, index + 2 < codes.count {
                    let color = xterm256Color(codes[index + 2].value)
                    if isForeground {
                        currentStyle.foreground = color
                        currentStyle.foregroundSource = .indexed
                    } else {
                        currentStyle.background = color
                        currentStyle.backgroundSource = .indexed
                    }
                    index += 2
                } else if codes[index + 1].value == 2, index + 4 < codes.count {
                    let color = TerminalTextStyle.rgb(red: codes[index + 2].value, green: codes[index + 3].value, blue: codes[index + 4].value)
                    if isForeground {
                        currentStyle.foreground = color
                        currentStyle.foregroundSource = .rgb
                    } else {
                        currentStyle.background = color
                        currentStyle.backgroundSource = .rgb
                    }
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    private func applyUnderlineSgr(_ element: CsiParameterElement) {
        guard element.values.count > 1 else {
            currentStyle.underline = true
            return
        }
        currentStyle.underline = element.values[1] != 0
    }

    private func colorFromColonSgr(
        _ element: CsiParameterElement
    ) -> (color: SIMD4<Float>, source: TerminalColorSource)? {
        guard element.values.count > 1 else { return nil }
        switch element.values[1] {
        case 5:
            guard element.values.count > 2 else { return nil }
            return (xterm256Color(element.values[2]), .indexed)
        case 2:
            let colorComponents = Array(element.values.dropFirst(2).suffix(3))
            guard colorComponents.count == 3 else { return nil }
            return (
                TerminalTextStyle.rgb(
                    red: colorComponents[0],
                    green: colorComponents[1],
                    blue: colorComponents[2]
                ),
                .rgb
            )
        default:
            return nil
        }
    }

    private func terminalAnsiColor(_ index: Int, bright: Bool) -> SIMD4<Float> {
        let offset = bright ? DesignTokens.Color.ansiNormal.count : 0
        let clampedIndex = max(0, min(offset + index, terminalAnsiColors.count - 1))
        return terminalAnsiColors[clampedIndex]
    }

    private func xterm256Color(_ value: Int) -> SIMD4<Float> {
        let index = max(0, min(value, 255))
        if index < TerminalColorSettings.requiredAnsiColorCount {
            return terminalAnsiColors[index]
        }
        if terminalDefaultStyle.isLightBackground, index >= 250 {
            return lightThemeGray(index)
        }
        if index < 232 {
            let cube = index - 16
            let red = cube / 36
            let green = (cube / 6) % 6
            let blue = cube % 6
            func component(_ value: Int) -> Int { value == 0 ? 0 : 55 + value * 40 }
            return TerminalTextStyle.rgb(red: component(red), green: component(green), blue: component(blue))
        }
        let gray = 8 + (index - 232) * 10
        return TerminalTextStyle.rgb(red: gray, green: gray, blue: gray)
    }

    private func lightThemeGray(_ index: Int) -> SIMD4<Float> {
        let clamped = max(250, min(index, 255))
        // Keep Codex's muted gray panels visible without making them heavy blocks
        // on the lightty background.
        let component = 205 + (clamped - 250) * 6
        return TerminalTextStyle.rgb(red: component, green: component, blue: component)
    }

    // MARK: - Host forwarding

    /// Single choke point for every terminal reply the interpreter produces
    /// (DA1, DA2, CPR, XTWINOPS, DECRPM). Replies are dropped while persisted
    /// scrollback is being replayed so restored output cannot re-answer a
    /// previous session's queries into the live shell.
    private func sendTerminalResponse(_ text: String) {
        guard !isReplayingScrollback else { return }
        host?.sendTerminalResponse(text)
    }

    private func respondToOscQuery(_ code: String) {
        guard !isReplayingScrollback else { return }
        host?.respondToOscQuery(code)
    }

    private func dispatchTerminalIntegrationOsc(_ command: String) -> TerminalOSCDispatcher.Event {
        host?.dispatchTerminalIntegrationOsc(command) ?? .ignored
    }

    private func publishTitle() {
        host?.publishTitle()
    }

    private func handleTerminalIntegrationEvent(_ event: TerminalOSCDispatcher.Event) {
        host?.handleTerminalIntegrationEvent(event)
    }

    private func handleDesktopNotificationEvent(_ event: TerminalOSCDispatcher.Event) {
        host?.handleDesktopNotificationEvent(event)
    }

    private func handleClipboardWriteEvent(_ event: TerminalOSCDispatcher.Event) {
        host?.handleClipboardWriteEvent(event)
    }

    private func ringTerminalBell() {
        host?.ringTerminalBell()
    }

    private func updateScrollIndicator() {
        host?.updateScrollIndicator()
    }

    private func maxScrollbackOffset(visibleRows: Int? = nil) -> Int {
        host?.maxScrollbackOffset(visibleRows) ?? 0
    }

    private func reportTerminalFocusIfNeeded() {
        host?.reportTerminalFocusIfNeeded()
    }

    private func terminalCapabilityMetrics() -> TerminalCapabilityMetrics? {
        host?.terminalCapabilityMetrics()
    }

    func terminalColorSchemeMode() -> TerminalColorSchemeMode {
        host?.terminalColorSchemeMode() ?? TerminalColorSchemeMode(
            isLightBackground: terminalDefaultStyle.isLightBackground
        )
    }
}
