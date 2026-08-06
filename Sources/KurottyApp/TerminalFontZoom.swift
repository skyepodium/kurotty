import Foundation
import KurottyCore

enum TerminalFontZoomStep: Equatable {
    case increase
    case decrease
    /// Returns to the size Preferences configured, which is why the zoom is a
    /// layer over `terminal.fontSize` and never writes back into it.
    case reset
}

/// Pure arithmetic behind ⌘+ / ⌘- / ⌘0.
///
/// Kept out of the surface view so the clamping is testable without an NSView,
/// a window, or a settings file. Every result is clamped, including `reset`:
/// a settings file edited by hand can carry a size outside the bounds, and a
/// zoom must never be the thing that lets it through.
enum TerminalFontZoom {
    static let stepPT = DesignTokens.Typography.terminalFontZoomStepPT

    static func clamped(_ fontSizePT: Double) -> Double {
        min(
            SettingsDefaults.maximumTerminalFontSizePT,
            max(SettingsDefaults.minimumTerminalFontSizePT, fontSizePT)
        )
    }

    /// `currentPT` is what the terminal renders at right now; `configuredPT` is
    /// what Preferences holds. They differ only while a zoom is active.
    static func fontSizePT(
        applying step: TerminalFontZoomStep,
        currentPT: Double,
        configuredPT: Double
    ) -> Double {
        switch step {
        case .increase:
            return clamped(clamped(currentPT) + stepPT)
        case .decrease:
            return clamped(clamped(currentPT) - stepPT)
        case .reset:
            return clamped(configuredPT)
        }
    }
}

/// The app-wide zoom layer over `terminal.fontSize`.
///
/// The zoom is deliberately global and in-memory: the font plumbing is a single
/// `AppSettingsStore` broadcast that every surface re-reads, and there is no
/// per-surface appearance override to hang a per-window zoom on. Nothing here
/// is persisted, so Preferences stays the source of truth and ⌘0 has a real
/// size to return to.
///
/// Lifecycle: app-lifetime, main-actor only, and it owns nothing but two
/// doubles — no timer, observer, file handle, or cache to tear down. Surfaces
/// subscribe to the notification and drop their observer with themselves.
@MainActor
final class TerminalFontZoomCoordinator {
    static let shared = TerminalFontZoomCoordinator()

    static let didChangeNotification = Notification.Name("dev.kurotty.terminalFontZoom.didChange")

    /// The active zoom, together with the configured size it was derived from.
    /// Pairing them is what makes a Preferences edit win without an observer and
    /// without depending on notification delivery order: once the configured
    /// size moves, the stored zoom no longer describes it and is ignored.
    private var zoom: (configuredFontSizePT: Double, resolvedFontSizePT: Double)?

    private let loadConfiguredFontSizePT: () -> Double

    init(loadConfiguredFontSizePT: @escaping () -> Double = {
        ((try? AppSettingsStore.shared.load()) ?? .default).terminal.fontSize
    }) {
        self.loadConfiguredFontSizePT = loadConfiguredFontSizePT
    }

    /// The size a surface configured for `configuredFontSizePT` should render at.
    func fontSizePT(configuredFontSizePT: Double) -> Double {
        guard let zoom, zoom.configuredFontSizePT == configuredFontSizePT else {
            return TerminalFontZoom.clamped(configuredFontSizePT)
        }
        return zoom.resolvedFontSizePT
    }

    func apply(_ step: TerminalFontZoomStep) {
        let configuredFontSizePT = loadConfiguredFontSizePT()
        let previousFontSizePT = fontSizePT(configuredFontSizePT: configuredFontSizePT)
        let nextFontSizePT = TerminalFontZoom.fontSizePT(
            applying: step,
            currentPT: previousFontSizePT,
            configuredPT: configuredFontSizePT
        )
        // Landing back on the configured size clears the zoom rather than
        // recording a no-op one, so a stale pairing can never resurrect if the
        // configured size later returns to what it was.
        zoom = nextFontSizePT == TerminalFontZoom.clamped(configuredFontSizePT)
            ? nil
            : (configuredFontSizePT: configuredFontSizePT, resolvedFontSizePT: nextFontSizePT)
        // A press at either bound changes nothing, and repainting every pane for
        // it would be a visible stutter under key repeat.
        guard nextFontSizePT != previousFontSizePT else { return }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
