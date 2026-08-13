/// Canonical composition of conjoining Hangul jamo into precomposed syllables.
///
/// macOS filesystems store filenames decomposed, so anything that prints a path
/// — `ls`, `git log`, `find`, a build log — emits Korean as separate conjoining
/// jamo (U+1100 initial + U+1161 medial + U+11A8 final) instead of the
/// precomposed U+AC00-block syllable a Korean user expects to read. Held as
/// three cells the syllable renders as scattered jamo and reports the wrong
/// column count; recomposed it is one wide cell, which is what every other
/// terminal shows.
///
/// This is display-side only. Nothing Kurotty sends back to the shell passes
/// through here: the filesystem's own bytes are authoritative on the input side,
/// and normalizing a path on its way to the PTY would produce a name that does
/// not exist. It is also unrelated to the macOS IME rule that AppKit owns live
/// jamo composition — that rule is about `setMarkedText` preedit for keystrokes
/// the user is typing, whereas this operates on committed bytes the child
/// process already wrote.
///
/// The arithmetic is Unicode 3.12 "Hangul Syllable Composition" rather than
/// `precomposedStringWithCanonicalMapping`, because Foundation's NFC leaves an
/// already-precomposed LV syllable followed by a trailing jamo uncomposed
/// (`U+AC00 U+11A8` stays two scalars). That combination is exactly the
/// cross-chunk case below, so the standard algorithm is spelled out here where
/// it can be tested.
public enum TerminalHangulComposition {
    private enum Syllable {
        static let base: UInt32 = 0xAC00
        static let leadingBase: UInt32 = 0x1100
        static let vowelBase: UInt32 = 0x1161
        /// Index 0 of the trailing series means "no trailing consonant", so the
        /// first real trailing jamo is `trailingBase + 1` (U+11A8).
        static let trailingBase: UInt32 = 0x11A7
        static let leadingCount: UInt32 = 19
        static let vowelCount: UInt32 = 21
        static let trailingCount: UInt32 = 28
        static let vowelTrailingCount: UInt32 = vowelCount * trailingCount
        static let count: UInt32 = leadingCount * vowelTrailingCount
    }

    // MARK: - Scalar classification

    /// U+1100...U+1112. The extended leading jamo at U+A960 have no canonical
    /// decomposition and are deliberately excluded.
    public static func isLeadingJamo(_ scalar: Unicode.Scalar) -> Bool {
        (Syllable.leadingBase..<(Syllable.leadingBase + Syllable.leadingCount)).contains(scalar.value)
    }

    /// U+1161...U+1175.
    public static func isVowelJamo(_ scalar: Unicode.Scalar) -> Bool {
        (Syllable.vowelBase..<(Syllable.vowelBase + Syllable.vowelCount)).contains(scalar.value)
    }

    /// U+11A8...U+11C2.
    public static func isTrailingJamo(_ scalar: Unicode.Scalar) -> Bool {
        ((Syllable.trailingBase + 1)..<(Syllable.trailingBase + Syllable.trailingCount)).contains(scalar.value)
    }

    public static func isConjoiningJamo(_ scalar: Unicode.Scalar) -> Bool {
        isLeadingJamo(scalar) || isVowelJamo(scalar) || isTrailingJamo(scalar)
    }

    /// A precomposed syllable in the U+AC00 block.
    public static func isSyllable(_ scalar: Unicode.Scalar) -> Bool {
        (Syllable.base..<(Syllable.base + Syllable.count)).contains(scalar.value)
    }

    /// A precomposed syllable that still has room for a trailing consonant.
    public static func isSyllableWithoutTrailingConsonant(_ scalar: Unicode.Scalar) -> Bool {
        isSyllable(scalar) && (scalar.value - Syllable.base) % Syllable.trailingCount == 0
    }

    // MARK: - Character classification

    /// Every scalar is a conjoining jamo, so the cluster is decomposed Hangul
    /// and nothing else.
    public static func isConjoiningJamoCluster(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty && character.unicodeScalars.allSatisfy(isConjoiningJamo)
    }

    /// A jamo cluster that cannot begin a syllable of its own — a medial vowel
    /// or a final consonant. This is what may arrive after the syllable it
    /// belongs to has already been placed in a cell.
    public static func isSyllableContinuationCluster(_ character: Character) -> Bool {
        isConjoiningJamoCluster(character)
            && !character.unicodeScalars.contains(where: isLeadingJamo)
    }

    // MARK: - Composition

    /// Folds conjoining jamo runs into precomposed syllables. Any scalar that is
    /// not part of a composable jamo pair is passed through untouched and in
    /// order, so this is safe to run over arbitrary text.
    public static func composedScalars(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        for scalar in scalars {
            if let previous = output.last, let composed = composing(previous, scalar) {
                output[output.count - 1] = composed
                continue
            }
            output.append(scalar)
        }
        return output
    }

    private static func composing(_ first: Unicode.Scalar, _ second: Unicode.Scalar) -> Unicode.Scalar? {
        if isLeadingJamo(first), isVowelJamo(second) {
            let value = Syllable.base
                + (first.value - Syllable.leadingBase) * Syllable.vowelTrailingCount
                + (second.value - Syllable.vowelBase) * Syllable.trailingCount
            return Unicode.Scalar(value)
        }
        if isSyllableWithoutTrailingConsonant(first), isTrailingJamo(second) {
            return Unicode.Scalar(first.value + (second.value - Syllable.trailingBase))
        }
        return nil
    }

    /// The grapheme cluster with its jamo composed. Returns `character`
    /// unchanged when there is nothing to compose, so callers can apply this to
    /// every printable character without paying for the general case.
    public static func composed(_ character: Character) -> Character {
        let scalars = Array(character.unicodeScalars)
        guard scalars.contains(where: isConjoiningJamo) else { return character }
        let composed = composedScalars(scalars)
        guard composed.count != scalars.count else { return character }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: composed)
        let text = String(view)
        guard text.count == 1, let first = text.first else { return character }
        return first
    }

    /// The same composition applied to a whole string. Used to put a search
    /// query into the form the screen cells are stored in; a query pasted from
    /// Finder arrives decomposed and would otherwise miss every match under the
    /// regular-expression path, which does not compare by canonical equivalence.
    public static func composed(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: isConjoiningJamo) else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: composedScalars(scalars))
        return String(view)
    }

    /// The syllable formed by appending `continuation` to `character`, or `nil`
    /// when they do not canonically compose into a single syllable. Composition
    /// must collapse to exactly one scalar: a trailing jamo landing after an
    /// already-complete `LVT` syllable is not a continuation of it, and must not
    /// be folded in.
    public static func merging(_ character: Character, with continuation: Character) -> Character? {
        let scalars = Array(character.unicodeScalars) + Array(continuation.unicodeScalars)
        let composed = composedScalars(scalars)
        guard composed.count == 1, let scalar = composed.first, isSyllable(scalar) else {
            return nil
        }
        return Character(scalar)
    }
}
