import AppKit

enum TerminalTextInputRouter {
    @MainActor
    static func handleKeyDown(_ event: NSEvent, in view: NSView, hasMarkedText: Bool) -> Bool {
        guard shouldOfferToInputContext(event, hasMarkedText: hasMarkedText) else {
            return false
        }

        // interpretKeyEvents is the NSTextInputClient path that owns IME
        // composition. Once a text candidate is offered here, never fall back to
        // raw characters; Korean IME may otherwise leak intermediate jamo to PTY.
        view.interpretKeyEvents([event])
        log("keyDown interpreted marked=\(hasMarkedText) event=\(describe(event))")
        return true
    }

    static func committedText(from string: Any) -> String {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        return composingCompatibilityHangulJamo((text as NSString).precomposedStringWithCanonicalMapping)
    }

    static func logInsertText(_ text: String, replacementRange: NSRange) {
        log("insertText text=\(debugText(text)) replacement=\(NSStringFromRange(replacementRange))")
    }

    static func logMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange) {
        log("setMarkedText text=\(debugText(text)) selected=\(NSStringFromRange(selectedRange)) replacement=\(NSStringFromRange(replacementRange))")
    }

    static func logUnmarkText() {
        log("unmarkText")
    }

    static func logPTYWrite(_ text: String, source: String) {
        log("ptyWrite source=\(source) utf8=\(text.data(using: .utf8)?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "") text=\(debugText(text))")
    }

    private static func shouldOfferToInputContext(_ event: NSEvent, hasMarkedText: Bool) -> Bool {
        if hasMarkedText {
            return true
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }

        return !(event.characters ?? "").isEmpty ||
            !(event.charactersIgnoringModifiers ?? "").isEmpty
    }

    private static func composingCompatibilityHangulJamo(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = ""
        var index = 0

        while index < scalars.count {
            guard let leadingIndex = leadingCompatibilityJamoIndexByScalar[scalars[index]],
                  let vowel = compatibilityVowelMatch(in: scalars, at: index + 1)
            else {
                output.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }

            let trailingStartIndex = index + 1 + vowel.length
            let trailing = compatibilityTrailingMatch(in: scalars, at: trailingStartIndex)
            let syllableOffset = (leadingIndex * compatibilityVowelCount + vowel.index) * compatibilityTrailingCount + trailing.index
            let syllableValue = hangulSyllableBase + UInt32(syllableOffset)
            output.unicodeScalars.append(UnicodeScalar(syllableValue)!)
            index = trailingStartIndex + trailing.length
        }

        return output
    }

    private static func compatibilityVowelMatch(
        in scalars: [UnicodeScalar],
        at index: Int
    ) -> (index: Int, length: Int)? {
        guard index < scalars.count else { return nil }
        if index + 1 < scalars.count {
            let pair = CompatibilityJamoPair(first: scalars[index], second: scalars[index + 1])
            if let combinedIndex = combinedCompatibilityVowelIndexByPair[pair] {
                return (combinedIndex, 2)
            }
        }
        guard let vowelIndex = vowelCompatibilityJamoIndexByScalar[scalars[index]] else {
            return nil
        }
        return (vowelIndex, 1)
    }

    private static func compatibilityTrailingMatch(
        in scalars: [UnicodeScalar],
        at index: Int
    ) -> (index: Int, length: Int) {
        guard index < scalars.count,
              let trailingIndex = trailingCompatibilityJamoIndexByScalar[scalars[index]]
        else {
            return (0, 0)
        }

        if index + 1 < scalars.count {
            let pair = CompatibilityJamoPair(first: scalars[index], second: scalars[index + 1])
            if let combinedIndex = combinedCompatibilityTrailingIndexByPair[pair],
               !startsCompatibilityVowel(in: scalars, at: index + 2) {
                return (combinedIndex, 2)
            }
        }

        if leadingCompatibilityJamoIndexByScalar[scalars[index]] != nil,
           startsCompatibilityVowel(in: scalars, at: index + 1) {
            return (0, 0)
        }

        return (trailingIndex, 1)
    }

    private static func startsCompatibilityVowel(in scalars: [UnicodeScalar], at index: Int) -> Bool {
        compatibilityVowelMatch(in: scalars, at: index) != nil
    }

    private static let hangulSyllableBase: UInt32 = 0xAC00
    private static let compatibilityVowelCount = 21
    private static let compatibilityTrailingCount = 28

    private struct CompatibilityJamoPair: Hashable {
        let first: UnicodeScalar
        let second: UnicodeScalar
    }

    private static let leadingCompatibilityJamoIndexByScalar = indexByScalar([
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ])

    private static let vowelCompatibilityJamoIndexByScalar = indexByScalar([
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ",
        "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ", "ㅣ",
    ])

    private static let trailingCompatibilityJamoIndexByScalar = indexByScalar([
        "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ",
        "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ", "ㅆ",
        "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ], indexOffset: 1)

    private static let combinedCompatibilityVowelIndexByPair = pairIndexMap([
        ("ㅗ", "ㅏ", "ㅘ"),
        ("ㅗ", "ㅐ", "ㅙ"),
        ("ㅗ", "ㅣ", "ㅚ"),
        ("ㅜ", "ㅓ", "ㅝ"),
        ("ㅜ", "ㅔ", "ㅞ"),
        ("ㅜ", "ㅣ", "ㅟ"),
        ("ㅡ", "ㅣ", "ㅢ"),
    ], indexes: vowelCompatibilityJamoIndexByScalar)

    private static let combinedCompatibilityTrailingIndexByPair = pairIndexMap([
        ("ㄱ", "ㅅ", "ㄳ"),
        ("ㄴ", "ㅈ", "ㄵ"),
        ("ㄴ", "ㅎ", "ㄶ"),
        ("ㄹ", "ㄱ", "ㄺ"),
        ("ㄹ", "ㅁ", "ㄻ"),
        ("ㄹ", "ㅂ", "ㄼ"),
        ("ㄹ", "ㅅ", "ㄽ"),
        ("ㄹ", "ㅌ", "ㄾ"),
        ("ㄹ", "ㅍ", "ㄿ"),
        ("ㄹ", "ㅎ", "ㅀ"),
        ("ㅂ", "ㅅ", "ㅄ"),
    ], indexes: trailingCompatibilityJamoIndexByScalar)

    private static func indexByScalar(_ values: [String], indexOffset: Int = 0) -> [UnicodeScalar: Int] {
        Dictionary(uniqueKeysWithValues: values.enumerated().map { index, value in
            (compatibilityJamoScalar(value), index + indexOffset)
        })
    }

    private static func pairIndexMap(
        _ values: [(String, String, String)],
        indexes: [UnicodeScalar: Int]
    ) -> [CompatibilityJamoPair: Int] {
        Dictionary(uniqueKeysWithValues: values.map { first, second, combined in
            (
                CompatibilityJamoPair(
                    first: compatibilityJamoScalar(first),
                    second: compatibilityJamoScalar(second)
                ),
                indexes[compatibilityJamoScalar(combined)]!
            )
        })
    }

    private static func compatibilityJamoScalar(_ value: String) -> UnicodeScalar {
        value.unicodeScalars.first!
    }

    private static func describe(_ event: NSEvent) -> String {
        "keyCode=\(event.keyCode) chars=\(debugText(event.characters ?? "")) ignoring=\(debugText(event.charactersIgnoringModifiers ?? "")) flags=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)"
    }

    private static func debugText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{1b}", with: "\\e")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func log(_ message: String) {
        guard DebugOptions.inputClient else { return }
        NSLog("Kurotty input-client: %@", message)
    }
}
