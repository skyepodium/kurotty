import AppKit

/// Shared constraint recipe for the sidebar panels' centered empty states
/// (command history, agent sessions, file explorer).
///
/// The empty state must be centered in the *list region* — the container that
/// holds the scroll view — never in the whole panel. Centering on the panel
/// let a tall wrapped message push its icon up into the section header and the
/// search pill, which is exactly the overlap this recipe removes.
///
/// Two further rules make the result deterministic:
/// - the label is pinned to both container edges with equality constraints, so
///   `NSTextField`'s wrapping height resolves from a known width instead of an
///   unbounded intrinsic width fighting inequality constraints;
/// - vertical centering is optional (`.defaultHigh`) while the top and bottom
///   inset constraints are required, so a list region too short for the
///   message pins the message to the top of the region rather than letting it
///   climb over the chrome above.
enum TerminalSidebarEmptyStateLayout {
    static func constraints(
        iconView: NSImageView,
        label: NSTextField,
        in container: NSView,
        insetX: CGFloat,
        insetY: CGFloat
    ) -> [NSLayoutConstraint] {
        let centerY = label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        centerY.priority = .defaultHigh
        return [
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.topAnchor.constraint(
                greaterThanOrEqualTo: container.topAnchor,
                constant: insetY
            ),
            iconView.bottomAnchor.constraint(
                equalTo: label.topAnchor,
                constant: -DesignTokens.Component.commandHistoryEmptyStateGapPX
            ),

            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insetX),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insetX),
            label.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor,
                constant: -insetY
            ),
            centerY,
        ]
    }

    /// True when the message cannot be drawn inside the label's own frame.
    ///
    /// This is the shape of the original bug: with only `centerX` plus
    /// `leading >=` / `trailing <=` constraints, Auto Layout resolved the
    /// wrapping label to a 4pt-wide frame. `NSTextField` does not clip, so the
    /// sentence was drawn far outside that frame — over the search pill and
    /// the section header. Layout regression tests assert this stays false.
    static func textOverflowsFrame(label: NSTextField) -> Bool {
        let text = label.attributedStringValue
        guard text.length > 0, label.frame.width > 0 else {
            return false
        }
        let bounds = text.boundingRect(
            with: NSSize(width: label.frame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return bounds.height.rounded(.down) > label.frame.height.rounded(.up)
    }
}
