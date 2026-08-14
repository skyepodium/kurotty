import Foundation

/// A command that lists things, and how to read its output as choices.
///
/// The shape a picker needs is always the same — run something, get rows, show
/// a label, keep some fields — and it is worth saying once rather than once per
/// tool. `kubectl get pods -o json`, `docker ps --format json`, `gh pr list
/// --json`, `tmux ls`: same source, different arguments.
///
/// Pure: this decodes bytes into choices. Running the command, showing the
/// list, and writing the result are all somebody else's job.
struct QuickCommandPickSource: Equatable {
    /// How the listing command spells its output.
    enum Format: Equatable {
        /// One JSON document with an array inside it, at a dotted path.
        /// `kubectl get -o json` puts it at `items`.
        case jsonArray(itemsPath: String)
        /// One JSON object per line, which is what `docker ps --format json`
        /// and `gh` produce.
        case jsonLines
    }

    /// One row the user can choose.
    struct Choice: Equatable {
        /// What the row reads as.
        let label: String
        /// The values this row would fill a template with.
        let values: [String: String]
    }

    /// The command that produces the listing.
    let command: String
    let format: Format
    /// Placeholder name to a dotted path into each row, e.g.
    /// `["pod": "metadata.name"]`.
    let fields: [String: String]
    /// How a row reads. Filled from `fields`, and *not* shell-quoted: this is
    /// text for a person to look at, never text for a shell to run.
    let label: String

    /// Reads a listing into choices, skipping rows it cannot describe.
    ///
    /// A row missing a field it was told to carry is dropped rather than shown
    /// with a hole in it: a picker whose rows are half-filled invites choosing
    /// one, and choosing one would produce a command with a missing argument.
    func choices(from output: Data) -> [Choice] {
        rows(in: output).compactMap { row in
            var values: [String: String] = [:]
            for (name, path) in fields {
                guard let value = Self.value(at: path, in: row) else {
                    return nil
                }
                values[name] = value
            }

            return Choice(label: Self.rendered(label, with: values), values: values)
        }
    }

    private func rows(in output: Data) -> [[String: Any]] {
        switch format {
        case let .jsonArray(itemsPath):
            guard let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
                  let items = Self.container(at: itemsPath, in: root) as? [[String: Any]]
            else {
                return []
            }
            return items
        case .jsonLines:
            return output
                .split(separator: UInt8(ascii: "\n"))
                .compactMap { line in
                    try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                }
        }
    }

    /// A dotted path into a decoded object, as a string.
    ///
    /// Numbers and booleans are rendered rather than refused, because a
    /// listing's useful columns include restart counts and ready flags and a
    /// picker that could only show strings would be missing exactly those.
    static func value(at path: String, in row: [String: Any]) -> String? {
        switch container(at: path, in: row) {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func container(at path: String, in row: [String: Any]) -> Any? {
        var current: Any? = row

        for component in path.split(separator: ".") {
            guard let object = current as? [String: Any] else {
                return nil
            }
            current = object[String(component)]
        }

        return current
    }

    /// A label with its holes filled and nothing quoted.
    ///
    /// Separate from `QuickCommandTemplate.filled` on purpose: that one quotes
    /// because its output reaches a shell, and quoting a label would show the
    /// user `'web-7d9f'` instead of `web-7d9f`. Two templates that look alike
    /// and mean different things are worth two functions.
    private static func rendered(_ template: String, with values: [String: String]) -> String {
        var output = ""
        var name: String?

        for character in template {
            switch character {
            case "{":
                name = ""
            case "}":
                if let finished = name {
                    output += values[finished] ?? ""
                    name = nil
                } else {
                    output.append(character)
                }
            default:
                if name != nil {
                    name?.append(character)
                } else {
                    output.append(character)
                }
            }
        }

        return output
    }
}
