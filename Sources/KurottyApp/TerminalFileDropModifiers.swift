import AppKit

/// Maps the modifiers held at drop time onto a path spelling.
///
/// Split out from `TerminalFileDropFormatter` so the formatter stays free of
/// AppKit, and kept out of the view so the precedence rule is testable.
enum TerminalFileDropModifiers {
    /// Option inserts the file name alone, Shift inserts a path relative to the
    /// pane's directory, and anything else inserts the absolute path.
    ///
    /// Option wins when both are held: it is the more destructive edit of the
    /// two — it drops the directory entirely — so the ambiguous combination
    /// resolves to the interpretation the user can see is wrong at a glance.
    /// Command and Control are ignored; the system reserves them during a drag.
    static func style(for modifiers: NSEvent.ModifierFlags) -> TerminalFileDropFormatter.PathStyle {
        if modifiers.contains(.option) { return .name }
        if modifiers.contains(.shift) { return .relative }
        return .absolute
    }
}
