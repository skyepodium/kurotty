import AppKit

/// Keeps constraint constants tied to the design token they came from.
///
/// Most chrome re-reads its tokens for free: colors are re-applied on every
/// `applyChromeTheme`, fonts are rebuilt by `Typography.Role.apply(to:color:)`,
/// and outline row heights come from a delegate the list asks again on every
/// `reloadData`. Constraints do not. A `heightAnchor.constraint(equalToConstant:)`
/// installed once at init keeps whatever number it was given, which is exactly
/// how a 30pt row of type ends up clipped inside a 20pt box after the user
/// raises the UI text scale.
///
/// A view with scaled constants registers them here instead of holding one
/// stored property per constraint, and replays them from the same broadcast
/// that repaints it.
@MainActor
final class ChromeMetricBindings {
    private var bindings: [(constraint: NSLayoutConstraint, metric: () -> CGFloat)] = []

    /// Sets `constraint` to the token's value now and remembers how to re-read
    /// it. Returns the constraint so it can be dropped straight into an
    /// `NSLayoutConstraint.activate` list.
    @discardableResult
    func bind(
        _ constraint: NSLayoutConstraint,
        to metric: @escaping () -> CGFloat
    ) -> NSLayoutConstraint {
        constraint.constant = metric()
        bindings.append((constraint, metric))
        return constraint
    }

    /// Re-reads every bound token. Cheap enough to call on any re-theme: the
    /// bindings are a handful per view and Auto Layout ignores a constant that
    /// has not moved.
    func reapply() {
        for binding in bindings {
            binding.constraint.constant = binding.metric()
        }
    }
}
