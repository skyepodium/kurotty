import Foundation

/// Everything the one-shot diagnostics report is allowed to know. The caller
/// collects it; `TerminalDiagnosticsReport.build` is pure and does no I/O, so
/// what is redacted is decided in one reviewable place.
///
/// Deliberately absent, and never to be added: terminal content (screen cells,
/// scrollback rows, selection, clipboard), command text, environment values,
/// and full filesystem paths. This blob is written for bug reports.
struct TerminalDiagnosticsReportInput {
    struct Environment {
        let appVersion: String
        let operatingSystemVersion: String
        let architecture: String
        let rendererName: String
        let gpuName: String?
        let backingScaleFactor: Double
        let languageCode: String

        init(
            appVersion: String,
            operatingSystemVersion: String,
            architecture: String,
            rendererName: String,
            gpuName: String?,
            backingScaleFactor: Double,
            languageCode: String
        ) {
            self.appVersion = appVersion
            self.operatingSystemVersion = operatingSystemVersion
            self.architecture = architecture
            self.rendererName = rendererName
            self.gpuName = gpuName
            self.backingScaleFactor = backingScaleFactor
            self.languageCode = languageCode
        }
    }

    struct Pane {
        let paneIdentifier: String
        let columns: Int
        let rows: Int
        let cellWidthPX: Double
        let cellHeightPX: Double
        let isUsingAlternateScreen: Bool
        let isBracketedPasteEnabled: Bool
        let isColorSchemeUpdateModeEnabled: Bool
        let isReplayingScrollback: Bool
        /// Last path component only. Never the full working directory.
        let workingDirectoryName: String?
        let isRemoteWorkingDirectory: Bool
        let eventLedger: TerminalEventLedger.Diagnostics
        let latestTrace: TerminalTraceTimelineSummary?
        let resizeSourceOfTruth: TerminalResizeSourceOfTruthSummary?
        let scrollback: TerminalScrollbackDiagnosticsSummary?
        let renderDamage: String?
        /// Newest last. Rendered through `TerminalDiagnosticsReport` so payload
        /// text can never survive into the blob.
        let recentEvents: [TerminalEventLedger.Event]

        init(
            paneIdentifier: String,
            columns: Int,
            rows: Int,
            cellWidthPX: Double,
            cellHeightPX: Double,
            isUsingAlternateScreen: Bool,
            isBracketedPasteEnabled: Bool,
            isColorSchemeUpdateModeEnabled: Bool,
            isReplayingScrollback: Bool,
            workingDirectoryName: String?,
            isRemoteWorkingDirectory: Bool,
            eventLedger: TerminalEventLedger.Diagnostics,
            latestTrace: TerminalTraceTimelineSummary?,
            resizeSourceOfTruth: TerminalResizeSourceOfTruthSummary?,
            scrollback: TerminalScrollbackDiagnosticsSummary?,
            renderDamage: String?,
            recentEvents: [TerminalEventLedger.Event]
        ) {
            self.paneIdentifier = paneIdentifier
            self.columns = columns
            self.rows = rows
            self.cellWidthPX = cellWidthPX
            self.cellHeightPX = cellHeightPX
            self.isUsingAlternateScreen = isUsingAlternateScreen
            self.isBracketedPasteEnabled = isBracketedPasteEnabled
            self.isColorSchemeUpdateModeEnabled = isColorSchemeUpdateModeEnabled
            self.isReplayingScrollback = isReplayingScrollback
            self.workingDirectoryName = workingDirectoryName
            self.isRemoteWorkingDirectory = isRemoteWorkingDirectory
            self.eventLedger = eventLedger
            self.latestTrace = latestTrace
            self.resizeSourceOfTruth = resizeSourceOfTruth
            self.scrollback = scrollback
            self.renderDamage = renderDamage
            self.recentEvents = recentEvents
        }
    }

    let capturedAt: Date
    let environment: Environment
    let windowCount: Int
    let panes: [Pane]
    let coreMutationSource: TerminalCoreMutationSourceDiagnostic?
    let coreRuntimeBoundary: TerminalCoreRuntimeBoundaryDiagnostic?

    init(
        capturedAt: Date,
        environment: Environment,
        windowCount: Int,
        panes: [Pane],
        coreMutationSource: TerminalCoreMutationSourceDiagnostic?,
        coreRuntimeBoundary: TerminalCoreRuntimeBoundaryDiagnostic?
    ) {
        self.capturedAt = capturedAt
        self.environment = environment
        self.windowCount = windowCount
        self.panes = panes
        self.coreMutationSource = coreMutationSource
        self.coreRuntimeBoundary = coreRuntimeBoundary
    }
}

/// A single pasteable diagnostics blob in both JSON and Markdown form.
struct TerminalDiagnosticsReport: Equatable {
    let json: String
    let markdown: String
}

enum TerminalDiagnosticsReportBuilder {
    /// How many trailing ledger events each pane contributes. Bounded so the
    /// blob stays pasteable into an issue.
    static let recentEventLimit = 40
    /// Stand-in for a working directory whose name is unknown or withheld.
    static let redactedPlaceholder = "redacted"

    static func build(_ input: TerminalDiagnosticsReportInput) -> TerminalDiagnosticsReport {
        let object = jsonObject(for: input)
        return TerminalDiagnosticsReport(
            json: encode(object),
            markdown: markdown(for: input, json: encode(object))
        )
    }

    /// Redacted rendering of one ledger event: kind, sequence, trace, and
    /// counts. Payload text — including any OSC body — is reduced to its
    /// numeric command code, so no terminal content can ride along.
    static func redactedEventLine(_ event: TerminalEventLedger.Event) -> String {
        let detail: String
        switch event.payload {
        case let .ptyRead(byteCount):
            detail = "bytes=\(byteCount)"
        case let .parserEvent(parserEvent):
            detail = redactedParserEventDetail(parserEvent)
        case let .screenMutation(mutation):
            detail = redactedScreenMutationDetail(mutation)
        case let .renderFrame(frame):
            detail = "frame=\(frame.frameIndex) dirtyRegions=\(frame.dirtyRegionCount) fullRedraw=\(frame.fullRedraw)"
        }
        return "#\(event.sequence) \(event.kind) trace=\(event.traceID) \(detail)"
    }

    private static func redactedParserEventDetail(_ event: TerminalEventLedger.ParserEvent) -> String {
        switch event {
        case let .printable(byteCount):
            return "printable bytes=\(byteCount)"
        case let .control(kind, byteCount):
            return "control kind=\(redactedIdentifier(kind)) bytes=\(byteCount)"
        case let .escapeSequence(kind, byteCount):
            return "escapeSequence kind=\(redactedIdentifier(kind)) bytes=\(byteCount)"
        case let .osc(command, byteCount):
            return "osc command=\(oscCommandCode(command)) bytes=\(byteCount)"
        }
    }

    private static func redactedScreenMutationDetail(_ mutation: TerminalEventLedger.ScreenMutation) -> String {
        switch mutation {
        case let .writeCells(cellCount):
            return "writeCells cells=\(cellCount)"
        case let .eraseInDisplay(rowsAffected):
            return "eraseInDisplay rows=\(rowsAffected)"
        case let .scroll(rowsAffected):
            return "scroll rows=\(rowsAffected)"
        case let .resize(columns, rows):
            return "resize columns=\(columns) rows=\(rows)"
        }
    }

    /// Only the numeric OSC code survives; the payload after the first `;` is
    /// producer data and can contain titles, paths, and clipboard content.
    private static func oscCommandCode(_ command: String) -> String {
        let code = command.prefix { $0.isNumber }
        return code.isEmpty ? redactedPlaceholder : String(code)
    }

    /// Parser "kind" labels are Kurotty-authored tokens; anything that is not a
    /// plain identifier is withheld rather than trusted.
    private static func redactedIdentifier(_ value: String) -> String {
        let isPlainIdentifier = !value.isEmpty && value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        return isPlainIdentifier ? value : redactedPlaceholder
    }

    /// The last path component of a working directory, or `nil`. Any value that
    /// still looks like a path is refused instead of trimmed, so a caller
    /// mistake cannot leak a home directory.
    static func workingDirectoryName(fromPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != "/", !name.contains("/") else { return nil }
        return name
    }

    private static func jsonObject(for input: TerminalDiagnosticsReportInput) -> [String: Any] {
        let environment = input.environment
        var object: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: input.capturedAt),
            "app": [
                "version": environment.appVersion,
                "language": environment.languageCode,
            ],
            "system": [
                "os": environment.operatingSystemVersion,
                "architecture": environment.architecture,
            ],
            "renderer": [
                "name": environment.rendererName,
                "gpu": environment.gpuName ?? redactedPlaceholder,
                "backingScaleFactor": environment.backingScaleFactor,
            ],
            "windowCount": input.windowCount,
            "paneCount": input.panes.count,
            "panes": input.panes.map(paneObject),
        ]
        object["coreBridge"] = [
            "mutationSource": input.coreMutationSource?.description ?? redactedPlaceholder,
            "runtimeBoundary": input.coreRuntimeBoundary?.description ?? redactedPlaceholder,
        ]
        return object
    }

    private static func paneObject(_ pane: TerminalDiagnosticsReportInput.Pane) -> [String: Any] {
        var object: [String: Any] = [
            "paneIdentifier": pane.paneIdentifier,
            "grid": ["columns": pane.columns, "rows": pane.rows],
            "cellSizePX": ["width": pane.cellWidthPX, "height": pane.cellHeightPX],
            "modes": [
                "alternateScreen": pane.isUsingAlternateScreen,
                "bracketedPaste": pane.isBracketedPasteEnabled,
                "colorSchemeUpdates": pane.isColorSchemeUpdateModeEnabled,
                "replayingScrollback": pane.isReplayingScrollback,
            ],
            "workingDirectoryName": pane.workingDirectoryName ?? redactedPlaceholder,
            "workingDirectoryIsRemote": pane.isRemoteWorkingDirectory,
            "eventLedger": pane.eventLedger.description,
            "recentEvents": pane.recentEvents.suffix(recentEventLimit).map(redactedEventLine),
        ]
        object["latestTrace"] = pane.latestTrace?.description ?? redactedPlaceholder
        object["resize"] = pane.resizeSourceOfTruth?.description ?? redactedPlaceholder
        object["scrollback"] = pane.scrollback?.description ?? redactedPlaceholder
        object["renderDamage"] = pane.renderDamage ?? redactedPlaceholder
        return object
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func markdown(for input: TerminalDiagnosticsReportInput, json: String) -> String {
        let environment = input.environment
        var lines = [
            "# Kurotty Diagnostics Report",
            "",
            "- Captured: \(ISO8601DateFormatter().string(from: input.capturedAt))",
            "- App: \(environment.appVersion) (\(environment.languageCode))",
            "- OS: \(environment.operatingSystemVersion) (\(environment.architecture))",
            "- Renderer: \(environment.rendererName) gpu=\(environment.gpuName ?? redactedPlaceholder) scale=\(environment.backingScaleFactor)",
            "- Windows: \(input.windowCount), Panes: \(input.panes.count)",
            "- Core bridge mutation source: \(input.coreMutationSource?.description ?? redactedPlaceholder)",
            "- Core bridge runtime boundary: \(input.coreRuntimeBoundary?.description ?? redactedPlaceholder)",
            "",
            "No terminal output, command text, clipboard content, or full paths are included.",
            "",
        ]
        for (index, pane) in input.panes.enumerated() {
            lines.append("## Pane \(index + 1)")
            lines.append("")
            lines.append("- Identifier: \(pane.paneIdentifier)")
            lines.append("- Grid: \(pane.columns)x\(pane.rows) cell=\(pane.cellWidthPX)x\(pane.cellHeightPX)px")
            lines.append("- Directory name: \(pane.workingDirectoryName ?? redactedPlaceholder) remote=\(pane.isRemoteWorkingDirectory)")
            lines.append("- Events: \(pane.eventLedger.description)")
            lines.append("- Latest trace: \(pane.latestTrace?.description ?? redactedPlaceholder)")
            lines.append("- Resize: \(pane.resizeSourceOfTruth?.description ?? redactedPlaceholder)")
            lines.append("- Scrollback: \(pane.scrollback?.description ?? redactedPlaceholder)")
            lines.append("- Render damage: \(pane.renderDamage ?? redactedPlaceholder)")
            lines.append("")
            lines.append("```")
            lines.append(contentsOf: pane.recentEvents.suffix(recentEventLimit).map(redactedEventLine))
            lines.append("```")
            lines.append("")
        }
        lines.append("<details><summary>JSON</summary>")
        lines.append("")
        lines.append("```json")
        lines.append(json)
        lines.append("```")
        lines.append("")
        lines.append("</details>")
        return lines.joined(separator: "\n")
    }
}
