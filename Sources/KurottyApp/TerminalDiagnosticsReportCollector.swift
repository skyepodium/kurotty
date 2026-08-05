import AppKit
import KurottyCore
import Metal

/// Gathers the live inputs for the one-shot diagnostics report and puts the
/// result on the pasteboard. Collection lives here so
/// `TerminalDiagnosticsReportBuilder` stays pure and testable.
@MainActor
enum TerminalDiagnosticsReportCollector {
    static func makeInput(
        windows: [NSWindow] = NSApp.windows,
        now: Date = Date()
    ) -> TerminalDiagnosticsReportInput {
        let surfaces = windows.flatMap { window in
            window.contentView.map(terminalSurfaces(in:)) ?? []
        }
        let terminalWindows = windows.filter { window in
            window.contentView.map { !terminalSurfaces(in: $0).isEmpty } ?? false
        }
        // One short-lived bridge, read twice: creating a second would double the
        // native handle for no reason.
        let core = makeCoreDiagnosticsSource()
        return TerminalDiagnosticsReportInput(
            capturedAt: now,
            environment: makeEnvironment(),
            windowCount: terminalWindows.count,
            panes: surfaces.map { $0.diagnosticsReportPane() },
            coreMutationSource: (core as? TerminalCoreMutationSourceDiagnosing)?
                .mutationSourceDiagnostic,
            coreRuntimeBoundary: (core as? TerminalCoreRuntimeBoundaryDiagnosing)?
                .runtimeBoundaryDiagnostic
        )
    }

    static func build(
        windows: [NSWindow] = NSApp.windows,
        now: Date = Date()
    ) -> TerminalDiagnosticsReport {
        TerminalDiagnosticsReportBuilder.build(makeInput(windows: windows, now: now))
    }

    /// Copies the Markdown form, which carries the JSON in a collapsed section,
    /// so one paste serves both a human reader and a machine.
    @discardableResult
    static func copyToPasteboard(
        _ pasteboard: NSPasteboard = .general,
        windows: [NSWindow] = NSApp.windows,
        now: Date = Date()
    ) -> TerminalDiagnosticsReport {
        let report = build(windows: windows, now: now)
        pasteboard.clearContents()
        pasteboard.setString(report.markdown, forType: .string)
        return report
    }

    private static func makeEnvironment() -> TerminalDiagnosticsReportInput.Environment {
        TerminalDiagnosticsReportInput.Environment(
            appVersion: AppConstants.Bundle.displayVersion(),
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            rendererName: rendererName,
            gpuName: MTLCreateSystemDefaultDevice()?.name,
            backingScaleFactor: Double(NSScreen.main?.backingScaleFactor ?? 1),
            languageCode: AppLocalization.language.rawValue
        )
    }

    private static var architecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }

    private static var rendererName: String {
        MTLCreateSystemDefaultDevice() == nil ? "metal-unavailable" : "metal"
    }

    /// A short-lived bridge used only to read ownership diagnostics. The live
    /// panes own their own cores; creating one here would duplicate state.
    private static func makeCoreDiagnosticsSource() -> (any TerminalCore)? {
        TerminalCoreFactory.makeDefaultCore(
            cols: UInt32(AppConstants.Terminal.defaultColumns),
            rows: UInt32(AppConstants.Terminal.defaultRows)
        )
    }

    private static func terminalSurfaces(in view: NSView) -> [TerminalSurfaceView] {
        if let surface = view as? TerminalSurfaceView {
            return [surface]
        }
        return view.subviews.flatMap(terminalSurfaces(in:))
    }
}

/// Menu action object for "Copy Diagnostics Report". Keeps the Help menu out of
/// `AppDelegate`, matching how quick commands own their own menu target.
@MainActor
final class DiagnosticsReportMenuActionTarget: NSObject {
    static let shared = DiagnosticsReportMenuActionTarget()

    @objc func copyDiagnosticsReport(_ sender: Any?) {
        let report = TerminalDiagnosticsReportCollector.copyToPasteboard()
        NSLog(
            "%@: bytes=%d",
            AppConstants.Diagnostics.diagnosticsReportPrefix,
            report.markdown.utf8.count
        )
        presentConfirmation()
    }

    private func presentConfirmation() {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.diagnosticsReportCopiedTitle)
        alert.informativeText = AppLocalization.string(.diagnosticsReportCopiedMessage)
        alert.alertStyle = .informational
        alert.addButton(withTitle: AppLocalization.string(.ok))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
