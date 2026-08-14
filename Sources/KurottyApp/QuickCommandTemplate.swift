import Foundation

/// A command with holes in it, and the only way to fill them.
///
/// `kubectl exec -it {pod} -c {container} -- {shell}` is a template; the values
/// come from whatever the user picked out of a list, which means they come from
/// a cluster, a daemon, or a config file rather than from the person typing.
///
/// **Filling is the only operation, and it always quotes.** There is
/// deliberately no "insert this raw" — a template cannot opt out, because the
/// one call site that opted out would be the one that mattered. A value that
/// needs to be several words is a design mistake in the template, not a case to
/// support.
struct QuickCommandTemplate: Equatable {
    /// The template text, holes included.
    let text: String

    private enum Delimiter {
        static let open: Character = "{"
        static let close: Character = "}"
    }

    init(_ text: String) {
        self.text = text
    }

    /// Every placeholder name the template asks for, in the order it asks.
    ///
    /// Used to tell a source what it has to supply, so a template naming a
    /// field nobody produces is caught when the command is defined rather than
    /// when someone runs it.
    var placeholders: [String] {
        var names: [String] = []
        var name: String?

        for character in text {
            switch character {
            case Delimiter.open:
                name = ""
            case Delimiter.close:
                if let finished = name, !finished.isEmpty {
                    names.append(finished)
                }
                name = nil
            default:
                name?.append(character)
            }
        }

        return names
    }

    /// The command to run, with every value quoted into one shell word.
    ///
    /// A placeholder with no value is an error rather than an empty string:
    /// `kubectl exec -it  -c web` is a command that runs and does something
    /// other than what was meant, which is worse than one that does not run.
    func filled(with values: [String: String]) -> String? {
        var output = ""
        var name: String?

        for character in text {
            switch character {
            case Delimiter.open:
                name = ""
            case Delimiter.close:
                guard let finished = name else {
                    output.append(character)
                    continue
                }
                guard let value = values[finished] else {
                    return nil
                }
                output += ShellArgumentQuoting.quoted(value)
                name = nil
            default:
                if name != nil {
                    name?.append(character)
                } else {
                    output.append(character)
                }
            }
        }

        // An unterminated `{` means the template is malformed, and a malformed
        // template that half-runs is the failure this whole type exists to
        // prevent.
        guard name == nil else {
            return nil
        }

        return output
    }
}
