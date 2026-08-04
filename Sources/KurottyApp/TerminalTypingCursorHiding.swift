import AppKit
import KurottyCore

/// Mouse-hide-while-typing policy, ported from Orca's
/// `mouse-hide-while-typing.ts`. AppKit already restores the cursor on the next
/// mouse move via `NSCursor.setHiddenUntilMouseMoves(_:)`, so the only decision
/// left is whether a given `keyDown` counts as ordinary typing.
enum TerminalTypingCursorHiding {
    /// Default for `terminal.hideMouseCursorWhileTyping` (live-applied). The
    /// live value is owned by the settings file; callers pass it in so this
    /// type stays pure and never reads the filesystem on a key event.
    static var hideMouseCursorWhileTypingEnabled: Bool {
        SettingsDefaults.hideMouseCursorWhileTyping
    }

    /// Modifiers that mean "this is a shortcut, not typing".
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .function]

    /// - Parameters:
    ///   - characters: `NSEvent.characters` for the key event.
    ///   - modifierFlags: the event's modifier flags.
    ///   - isModalPresentationActive: `true` while a sheet, modal window, or
    ///     tracking menu owns the screen; the pointer must stay visible there.
    ///   - isEnabled: live value of `terminal.hideMouseCursorWhileTyping`.
    static func shouldHideCursor(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags,
        isModalPresentationActive: Bool,
        isEnabled: Bool = hideMouseCursorWhileTypingEnabled
    ) -> Bool {
        guard isEnabled else { return false }
        guard !isModalPresentationActive else { return false }
        guard modifierFlags.isDisjoint(with: shortcutModifiers) else { return false }
        guard let characters, !characters.isEmpty else { return false }
        return true
    }
}
