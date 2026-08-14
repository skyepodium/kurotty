import AppKit

/// The faces a renderer reaches for when the configured font has no glyph for
/// a character.
///
/// Shared because both renderers need the same answer. The glyph atlas walks
/// this list before asking CoreText, and it has to: on a machine with a Nerd
/// Font installed, `CTFontCreateForString` still answers `.LastResort` for a
/// powerline separator, because those live in the private use area and nothing
/// claims that range in the system cascade. The named list is what actually
/// resolves them, and a second renderer that skipped it would draw the empty
/// boxes the atlas does not — which is exactly what the HTML renderer did on
/// its first run.
enum TerminalGlyphFallbackFonts {
    /// Tried for any character the configured font lacks. Nerd Font variants
    /// come first because they carry the powerline and symbol ranges that
    /// prompts use most.
    static let general = [
        "MesloLGS NF",
        "MesloLGS Nerd Font Mono",
        "Symbols Nerd Font Mono",
        "Hack Nerd Font Mono",
        "JetBrainsMono Nerd Font Mono",
        "FiraCode Nerd Font Mono",
        "SF Mono",
        "Menlo",
    ]

    /// Tried ahead of `general` for CJK, where picking a symbol face first
    /// would find a glyph of the wrong shape rather than no glyph at all.
    static let cjk = [
        "Apple SD Gothic Neo",
        "AppleGothic",
        "Noto Sans CJK KR",
        "Noto Sans KR",
        "PingFang SC",
        "Hiragino Sans",
    ]

    /// The names above that this machine can actually resolve.
    ///
    /// A CSS stack ignores a family it cannot find, so filtering is not needed
    /// for correctness — it keeps the stack short enough to read in a
    /// stylesheet, and makes a machine missing every Nerd Font visible rather
    /// than silently producing boxes.
    static func installed(from names: [String], size: CGFloat) -> [String] {
        names.filter { NSFont(name: $0, size: size) != nil }
    }
}
