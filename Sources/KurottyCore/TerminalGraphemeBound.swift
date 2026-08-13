import Foundation

/// Keeps a single cell's grapheme cluster to a bounded number of unicode
/// scalars.
///
/// Combining marks have no natural end: `a` followed by an unbroken run of
/// U+0301 is still one grapheme cluster, so it is still one cell — and the
/// `Character` stored in that cell grows for as long as the child keeps
/// writing. The bound belongs at the boundary where terminal output becomes
/// cell content, and the limit itself is a caller's decision so it can live
/// with the rest of the parser's resource limits.
public enum TerminalGraphemeBound {
    /// The cluster when it fits, and otherwise its longest leading run of
    /// scalars that does.
    ///
    /// Truncation rather than rejection: the base character is the text the
    /// user came for, and dropping it because a hostile or corrupt stream
    /// appended marks to it would lose real content.
    public static func clamped(_ character: Character, maximumScalarCount: Int) -> Character {
        guard maximumScalarCount > 0 else { return character }
        guard character.unicodeScalars.count > maximumScalarCount else { return character }
        var scalars = String.UnicodeScalarView()
        for scalar in character.unicodeScalars.prefix(maximumScalarCount) {
            scalars.append(scalar)
        }
        return String(scalars).first ?? character
    }
}
