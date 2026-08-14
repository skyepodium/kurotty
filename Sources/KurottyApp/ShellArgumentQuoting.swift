import Foundation

/// Turns a value into one shell word that cannot be anything else.
///
/// **This is the whole security boundary for a command built from a list.** A
/// quick command reaches the shell as text on a pseudo-terminal — there is no
/// argv to hand it, because a PTY carries bytes and the shell does the parsing.
/// So a pod named `web; rm -rf /` substituted into `kubectl exec -it {pod}` is
/// not a wrong command, it is two commands, and the second one runs.
///
/// Single quotes, because inside them every byte is literal in every POSIX
/// shell — no expansion, no escapes, no history, no globbing. The single quote
/// itself is the only character that has to leave the quoted run, and it is
/// spelled by closing, escaping it outside, and opening again.
enum ShellArgumentQuoting {
    /// One value as a single shell word.
    ///
    /// Always quoted, even when the value looks harmless. A rule with an
    /// exception is a rule somebody has to check, and "looks harmless" is
    /// exactly the judgement an attacker writes their input against.
    static func quoted(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
