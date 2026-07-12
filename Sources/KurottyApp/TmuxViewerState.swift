import Foundation

struct TmuxPaneOutputReplay: Equatable, Sendable {
    let data: Data
    let startOffset: UInt64
    let nextOffset: UInt64
    let requiresFullReplay: Bool
}

struct TmuxBoundedOutputHistory: Equatable, Sendable {
    private static let targetChunkByteCount = 16 * 1024

    let byteLimit: Int
    private(set) var startOffset: UInt64 = 0
    private(set) var endOffset: UInt64 = 0

    private var chunks: [Data] = []
    private var firstChunkIndex = 0
    private var firstChunkByteOffset = 0
    private var retainedByteCount = 0

    init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    var data: Data {
        retainedData(droppingFirst: 0)
    }

    var isEmpty: Bool { retainedByteCount == 0 }
    var storageChunkCount: Int { max(0, chunks.count - firstChunkIndex) }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        endOffset += UInt64(data.count)
        guard byteLimit > 0 else {
            startOffset = endOffset
            return
        }

        if data.count >= byteLimit {
            chunks.removeAll(keepingCapacity: true)
            firstChunkIndex = 0
            firstChunkByteOffset = 0
            retainedByteCount = byteLimit
            startOffset = endOffset - UInt64(byteLimit)
            appendCompacted(Data(data.suffix(byteLimit)))
            return
        }

        appendCompacted(data)
        retainedByteCount += data.count
        trimOldestBytes(max(0, retainedByteCount - byteLimit))
        compactConsumedChunksIfNeeded()
    }

    func replay(after requestedOffset: UInt64?) -> TmuxPaneOutputReplay {
        let requestedOffset = requestedOffset ?? startOffset
        let cursorIsValid = requestedOffset >= startOffset && requestedOffset <= endOffset
        let replayStartOffset = cursorIsValid ? requestedOffset : startOffset
        let bytesToSkip = Int(replayStartOffset - startOffset)
        return TmuxPaneOutputReplay(
            data: retainedData(droppingFirst: bytesToSkip),
            startOffset: replayStartOffset,
            nextOffset: endOffset,
            requiresFullReplay: requestedOffset != replayStartOffset
        )
    }

    mutating func removeAll() {
        chunks.removeAll(keepingCapacity: true)
        firstChunkIndex = 0
        firstChunkByteOffset = 0
        retainedByteCount = 0
        startOffset = 0
        endOffset = 0
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.byteLimit == rhs.byteLimit
            && lhs.startOffset == rhs.startOffset
            && lhs.endOffset == rhs.endOffset
            && lhs.data == rhs.data
    }

    private mutating func trimOldestBytes(_ count: Int) {
        var remaining = count
        while remaining > 0, firstChunkIndex < chunks.count {
            let available = chunks[firstChunkIndex].count - firstChunkByteOffset
            if remaining < available {
                firstChunkByteOffset += remaining
                retainedByteCount -= remaining
                startOffset += UInt64(remaining)
                return
            }
            remaining -= available
            retainedByteCount -= available
            startOffset += UInt64(available)
            firstChunkIndex += 1
            firstChunkByteOffset = 0
        }
    }

    private mutating func appendCompacted(_ data: Data) {
        var remaining = data[...]
        if let lastIndex = chunks.indices.last,
           lastIndex >= firstChunkIndex,
           chunks[lastIndex].count < Self.targetChunkByteCount {
            let available = Self.targetChunkByteCount - chunks[lastIndex].count
            let prefixCount = min(available, remaining.count)
            chunks[lastIndex].append(contentsOf: remaining.prefix(prefixCount))
            remaining = remaining.dropFirst(prefixCount)
        }
        while !remaining.isEmpty {
            let chunkByteCount = min(Self.targetChunkByteCount, remaining.count)
            chunks.append(Data(remaining.prefix(chunkByteCount)))
            remaining = remaining.dropFirst(chunkByteCount)
        }
    }

    private mutating func compactConsumedChunksIfNeeded() {
        guard firstChunkIndex >= 64, firstChunkIndex * 2 >= chunks.count else { return }
        chunks.removeFirst(firstChunkIndex)
        firstChunkIndex = 0
    }

    private func retainedData(droppingFirst byteCount: Int) -> Data {
        var remainingToDrop = min(max(0, byteCount), retainedByteCount)
        var result = Data()
        result.reserveCapacity(retainedByteCount - remainingToDrop)
        guard firstChunkIndex < chunks.count else { return result }

        for chunkIndex in firstChunkIndex..<chunks.count {
            let chunk = chunks[chunkIndex]
            let initialOffset = chunkIndex == firstChunkIndex ? firstChunkByteOffset : 0
            let available = chunk.count - initialOffset
            if remainingToDrop >= available {
                remainingToDrop -= available
                continue
            }
            result.append(chunk.dropFirst(initialOffset + remainingToDrop))
            remainingToDrop = 0
        }
        return result
    }
}

struct TmuxPaneState: Equatable, Sendable {
    static let defaultOutputHistoryByteLimit = 4 * 1024 * 1024

    let id: String
    private(set) var title = ""
    private(set) var snapshot: TmuxPaneSnapshot?
    private var outputHistory: TmuxBoundedOutputHistory

    init(id: String, outputHistoryByteLimit: Int = Self.defaultOutputHistoryByteLimit) {
        self.id = id
        outputHistory = TmuxBoundedOutputHistory(byteLimit: outputHistoryByteLimit)
    }

    var output: Data { outputHistory.data }
    var outputHistoryByteLimit: Int { outputHistory.byteLimit }
    var outputHistoryStartOffset: UInt64 { outputHistory.startOffset }
    var outputHistoryEndOffset: UInt64 { outputHistory.endOffset }

    mutating func appendOutput(_ data: Data) {
        outputHistory.append(data)
    }

    mutating func installSnapshot(_ snapshot: TmuxPaneSnapshot) {
        self.snapshot = snapshot
        outputHistory.removeAll()
        outputHistory.append(snapshot.replayData)
    }

    mutating func setTitle(_ title: String) {
        self.title = title
    }

    func replayOutput(after offset: UInt64? = nil) -> TmuxPaneOutputReplay {
        outputHistory.replay(after: offset)
    }
}

struct TmuxWindowState: Equatable, Sendable {
    let id: String
    var name = ""
    var canonicalLayout: TmuxLayoutNode?
    var visibleLayout: TmuxLayoutNode?
    var layout: TmuxLayoutNode?
    var flags = ""
    var activePaneID: String?

    var isZoomed: Bool { flags.contains("Z") }
}

struct TmuxViewerState: Equatable, Sendable {
    private let paneOutputHistoryByteLimit: Int
    private(set) var isAttached = false
    private(set) var sessionID: String?
    private(set) var sessionName: String?
    private(set) var activeWindowID: String?
    private(set) var focusedPaneID: String?
    private(set) var windows: [String: TmuxWindowState] = [:]
    private(set) var windowOrder: [String] = []
    private(set) var panes: [String: TmuxPaneState] = [:]
    private(set) var lastError: String?

    init(paneOutputHistoryByteLimit: Int = TmuxPaneState.defaultOutputHistoryByteLimit) {
        self.paneOutputHistoryByteLimit = max(0, paneOutputHistoryByteLimit)
    }

    mutating func apply(_ event: TmuxControlEvent) {
        switch event {
        case .entered:
            isAttached = true
            sessionID = nil
            sessionName = nil
            resetTopology()
            lastError = nil
        case let .exited(reason):
            isAttached = false; lastError = reason
        case let .windowAdded(id):
            if windows[id] == nil { windows[id] = .init(id: id); windowOrder.append(id) }
        case let .windowClosed(id):
            windows[id] = nil; windowOrder.removeAll { $0 == id }
            if activeWindowID == id {
                activeWindowID = windowOrder.first
                focusedPaneID = activeWindowID.flatMap { windows[$0]?.activePaneID }
            }
            pruneOrphanedPanes()
        case let .windowRenamed(id, name):
            ensureWindow(id); windows[id]?.name = name
        case let .windowOrderChanged(ids):
            for id in ids { ensureWindow(id) }
            windowOrder = ids
        case let .layoutChanged(id, layout, visibleLayout, flags):
            ensureWindow(id)
            windows[id]?.canonicalLayout = layout
            windows[id]?.visibleLayout = visibleLayout
            windows[id]?.layout = visibleLayout
            windows[id]?.flags = flags
            for paneID in layout.paneIDs { ensurePane(paneID) }
            for paneID in visibleLayout.paneIDs { ensurePane(paneID) }
            pruneOrphanedPanes()
        case let .sessionChanged(id, name):
            if let sessionID, sessionID != id { resetTopology() }
            sessionID = id
            sessionName = name
        case let .sessionRenamed(id, name):
            if id == nil || id == sessionID { sessionName = name }
        case let .activeWindowChanged(sessionID, windowID):
            guard sessionID == self.sessionID else { break }
            ensureWindow(windowID)
            activeWindowID = windowID
            focusedPaneID = windows[windowID]?.activePaneID
        case let .activePaneChanged(windowID, paneID):
            guard windows[windowID] != nil else { break }
            ensurePane(paneID)
            windows[windowID]?.activePaneID = paneID
            if windowID == activeWindowID { focusedPaneID = paneID }
        case let .paneFocused(id):
            ensurePane(id); focusedPaneID = id
        case let .paneFocusChanged(id, isFocused):
            ensurePane(id)
            if isFocused {
                focusedPaneID = id
            } else if focusedPaneID == id {
                focusedPaneID = nil
            }
        case let .paneTitleChanged(sessionID, paneID, title):
            guard sessionID == self.sessionID, panes[paneID] != nil else { break }
            panes[paneID]?.setTitle(title)
        case let .output(id, data):
            ensurePane(id); panes[id]?.appendOutput(data)
        case let .configurationError(message):
            lastError = message
        case .locallyAborted, .blockBegan, .blockEnded, .blockFailed, .sessionsChanged,
             .clientSessionChanged, .subscriptionChanged, .responseLine, .notification, .malformed:
            break
        }
    }

    mutating func apply<S: Sequence>(_ events: S) where S.Element == TmuxControlEvent {
        for event in events { apply(event) }
    }

    mutating func recordError(_ message: String) {
        lastError = message
    }

    mutating func installSnapshot(_ snapshot: TmuxPaneSnapshot, for paneID: String) {
        ensurePane(paneID)
        panes[paneID]?.installSnapshot(snapshot)
    }

    mutating func pruneOrphanedPanes() {
        let referencedPaneIDs = Set(windows.values.flatMap { window in
            window.canonicalLayout?.paneIDs ?? window.layout?.paneIDs ?? []
        })
        panes = panes.filter { referencedPaneIDs.contains($0.key) }
        if let focusedPaneID, !referencedPaneIDs.contains(focusedPaneID) {
            self.focusedPaneID = activeWindowID.flatMap { windows[$0]?.activePaneID }
        }
    }

    private mutating func ensureWindow(_ id: String) {
        if windows[id] == nil { windows[id] = .init(id: id); windowOrder.append(id) }
    }

    private mutating func ensurePane(_ id: String) {
        if panes[id] == nil {
            panes[id] = .init(id: id, outputHistoryByteLimit: paneOutputHistoryByteLimit)
        }
    }

    private mutating func resetTopology() {
        activeWindowID = nil
        focusedPaneID = nil
        windows.removeAll(keepingCapacity: true)
        windowOrder.removeAll(keepingCapacity: true)
        panes.removeAll(keepingCapacity: true)
    }
}

enum TmuxSplitDirection: String, Sendable { case horizontal = "-h", vertical = "-v" }
enum TmuxResizeDirection: String, Sendable { case left = "L", right = "R", up = "U", down = "D" }
enum TmuxRotationDirection: String, Equatable, Sendable { case previous = "U", next = "D" }
enum TmuxPaneSwapDirection: String, Equatable, Sendable { case previous = "U", next = "D" }
enum TmuxLayoutSelection: Equatable, Sendable {
    case next
    case previous
    case evenHorizontal
    case evenVertical
}

enum TmuxCommandEncoder {
    static func listWindows(sessionID: String) -> Data {
        command(
            "list-windows -O index -t \(quote(sessionID)) -F \"#{window_id}|#{window_layout}|#{window_visible_layout}|#{window_flags}|#{window_active}|#{window_name}\""
        )
    }
    static func listWindowOrder(sessionID: String) -> Data {
        command("list-windows -O index -t \(quote(sessionID)) -F \"#{window_id}\"")
    }
    static func listPanes(sessionID: String) -> Data {
        command(
            "list-panes -s -t \(quote("\(sessionID):")) -F \"#{window_id}|#{pane_id}|#{pane_active}|#{pane_title}\""
        )
    }
    static func registerStateSubscriptions() -> Data {
        command(
            "refresh-client -B \(quote("kurotty-window-index:@*:#{window_index}")) "
                + "-B \(quote("kurotty-pane-title:%*:#{pane_title}"))"
        )
    }
    static func sendKeys(paneID: String, data: Data) -> Data {
        command("send-keys -t \(quote(paneID)) -H \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }
    static func selectPane(_ paneID: String) -> Data { command("select-pane -t \(quote(paneID))") }
    static func selectWindow(_ windowID: String) -> Data { command("select-window -t \(quote(windowID))") }
    static func splitPane(
        targetPaneID: String,
        direction: TmuxSplitDirection,
        before: Bool = false
    ) -> Data {
        let beforeFlag = before ? "-b " : ""
        return command("split-window \(beforeFlag)\(direction.rawValue) -t \(quote(targetPaneID))")
    }
    static func killPane(_ paneID: String) -> Data { command("kill-pane -t \(quote(paneID))") }
    static func killWindow(_ windowID: String) -> Data { command("kill-window -t \(quote(windowID))") }
    static func resizePane(_ paneID: String, direction: TmuxResizeDirection, cells: Int) -> Data {
        command("resize-pane -t \(quote(paneID)) -\(direction.rawValue) \(max(1, cells))")
    }
    static func resizePane(_ paneID: String, columns: Int, rows: Int) -> Data {
        command("resize-pane -t \(quote(paneID)) -x \(max(1, columns)) -y \(max(1, rows))")
    }
    static func resizeClient(windowID: String? = nil, columns: Int, rows: Int) -> Data {
        let dimensions = "\(max(1, columns))x\(max(1, rows))"
        let size = windowID.map { "\($0):\(dimensions)" } ?? dimensions
        return command("refresh-client -C \(quote(size))")
    }
    static func rotateWindow(_ windowID: String, direction: TmuxRotationDirection) -> Data {
        command("rotate-window -\(direction.rawValue) -t \(quote(windowID))")
    }
    static func swapPane(_ paneID: String, direction: TmuxPaneSwapDirection) -> Data {
        command("swap-pane -\(direction.rawValue) -t \(quote(paneID))")
    }
    static func toggleZoom(_ paneID: String) -> Data {
        command("resize-pane -Z -t \(quote(paneID))")
    }
    static func selectLayout(_ selection: TmuxLayoutSelection, targetPaneID: String) -> Data {
        switch selection {
        case .next:
            command("select-layout -n -t \(quote(targetPaneID))")
        case .previous:
            command("select-layout -p -t \(quote(targetPaneID))")
        case .evenHorizontal:
            command("select-layout -t \(quote(targetPaneID)) even-horizontal")
        case .evenVertical:
            command("select-layout -t \(quote(targetPaneID)) even-vertical")
        }
    }
    static func capturePane(_ paneID: String, historyLines: Int = 10_000) -> Data {
        captureCurrentScreen(paneID, historyLines: historyLines)
    }
    static func captureCurrentScreen(_ paneID: String, historyLines: Int = 10_000) -> Data {
        command("capture-pane -p -e -q -J -N -S -\(max(0, historyLines)) -t \(quote(paneID))")
    }
    static func captureAlternateScreen(_ paneID: String, historyLines: Int = 10_000) -> Data {
        command("capture-pane -p -e -q -J -N -a -S -\(max(0, historyLines)) -t \(quote(paneID))")
    }
    static func listPaneState(_ paneID: String) -> Data {
        let fields = [
            "pane_id", "pane_width", "pane_height", "alternate_on",
            "alternate_saved_x", "alternate_saved_y", "cursor_x", "cursor_y",
            "scroll_region_upper", "scroll_region_lower", "pane_tabs", "cursor_flag",
            "insert_flag", "origin_flag", "keypad_cursor_flag", "keypad_flag", "wrap_flag",
            "mouse_standard_flag", "mouse_button_flag", "mouse_any_flag",
            "mouse_utf8_flag", "mouse_sgr_flag", "bracket_paste_flag", "pane_key_mode",
        ]
        let format = (fields.map { "\($0)=#{\($0)}" } + [
            "extended_keys_format=#{extended-keys-format}",
            "session_attached=#{session_attached}",
        ]).joined(separator: "\t")
        let paneFilter = "#{==:#{pane_id},\(paneID)}"
        return command(
            "list-panes -t \(quote(paneID)) -f \(quote(paneFilter)) -F \(doubleQuote(format))"
        )
    }
    static func capturePendingOutput(_ paneID: String) -> Data {
        command("capture-pane -p -P -C -t \(quote(paneID))")
    }
    static func attachedClientCount(_ paneID: String) -> Data {
        command("display-message -p -t \(quote(paneID)) '#{session_attached}'")
    }
    static func suspendPaneOutput(_ paneID: String) -> Data {
        command("refresh-client -A \(quote("\(paneID):off"))")
    }
    static func resumePaneOutput(_ paneID: String) -> Data {
        command("refresh-client -A \(quote("\(paneID):on"))")
    }
    static func newWindow(sessionID: String? = nil) -> Data {
        guard let sessionID else { return command("new-window") }
        return command("new-window -t \(quote("\(sessionID):"))")
    }
    static func detachClient() -> Data { command("detach-client") }

    private static func command(_ value: String) -> Data { Data((value + "\n").utf8) }
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func doubleQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
