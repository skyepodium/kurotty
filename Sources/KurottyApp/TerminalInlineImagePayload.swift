import Foundation

/// An `OSC 1337 ; File = …` payload, as the terminal received it.
///
/// iTerm2's inline-image protocol: a semicolon-separated list of `key=value`
/// arguments, a colon, then the file itself in base64. Everything about it is
/// declared by the sending program, which is why nothing here trusts a
/// declaration — the size is checked against the bytes that actually arrived,
/// and the dimensions are read as requests rather than as facts.
///
/// Pure and rendererless. Parsing an escape sequence is not a drawing problem,
/// and keeping it here means the shape of the protocol can be tested against
/// the strings a real shell emits without a terminal, a screen or a web view.
struct TerminalInlineImagePayload: Equatable {
    /// How wide or tall the sender asked the image to be.
    enum Extent: Equatable {
        /// Whatever the image's own pixels come to.
        case auto
        /// A count of terminal cells.
        case cells(Int)
        /// A count of device pixels.
        case pixels(Int)
        /// A share of the terminal's width or height, 1...100.
        case percent(Int)
    }

    /// The file's own name, when the sender supplied one. Carried for
    /// accessibility rather than for display: an image in a terminal has no
    /// caption, and a screen reader otherwise has nothing to say about it.
    var name: String?
    var width: Extent
    var height: Extent
    /// Whether the sender wants the aspect ratio kept when both extents are
    /// given. Defaults to true, as in iTerm2.
    var preservesAspectRatio: Bool
    var data: Data

    private enum Key {
        static let file = "File"
        static let name = "name"
        static let width = "width"
        static let height = "height"
        static let inline = "inline"
        static let preserveAspectRatio = "preserveAspectRatio"
    }

    private enum Limit {
        /// Largest cell count an extent may ask for.
        ///
        /// A declared size is a request from a program, and `width=99999` is a
        /// request to lay out a hundred thousand columns. Clamping here means
        /// the layout never sees a number it has to defend against.
        static let extentCELLS = 1_000
        /// Largest pixel count an extent may ask for, for the same reason.
        static let extentPIXELS = 20_000
    }

    /// Parses a payload, or returns nil when this is not an inline image.
    ///
    /// The same OSC 1337 carries iTerm2's notifications, so "not an image" is
    /// an ordinary outcome rather than a failure, and the caller falls through
    /// to whatever else claims the sequence.
    static func parse(_ payload: String) -> TerminalInlineImagePayload? {
        guard let colon = payload.firstIndex(of: ":") else {
            return nil
        }

        let header = payload[payload.startIndex..<colon]
        let encoded = payload[payload.index(after: colon)...]
        var arguments = header.split(separator: ";", omittingEmptySubsequences: false)

        guard let declaration = arguments.first,
              let (key, value) = keyAndValue(declaration),
              key == Key.file
        else {
            return nil
        }
        arguments.removeFirst()

        // `File=<name>` is the older spelling, where the value is the name
        // rather than empty. Both forms reach the same place.
        var image = TerminalInlineImagePayload(
            name: value.isEmpty ? nil : decodedName(value),
            width: .auto,
            height: .auto,
            preservesAspectRatio: true,
            data: Data()
        )
        var isInline = false

        for argument in arguments {
            guard let (key, value) = keyAndValue(argument) else {
                continue
            }
            switch key {
            case Key.name:
                image.name = decodedName(value)
            case Key.width:
                image.width = extent(value)
            case Key.height:
                image.height = extent(value)
            case Key.inline:
                isInline = value == "1"
            case Key.preserveAspectRatio:
                image.preservesAspectRatio = value != "0"
            default:
                continue
            }
        }

        // Without `inline=1` the sender is asking the terminal to *download* a
        // file, which is a different feature and one this terminal does not
        // have. Drawing it instead would put a program's bytes on screen under
        // an instruction that never asked for that.
        guard isInline else {
            return nil
        }
        guard let data = Data(base64Encoded: String(encoded), options: .ignoreUnknownCharacters),
              !data.isEmpty
        else {
            return nil
        }

        image.data = data
        return image
    }

    private static func keyAndValue(_ argument: Substring) -> (String, String)? {
        guard let equals = argument.firstIndex(of: "=") else {
            return nil
        }
        return (
            String(argument[argument.startIndex..<equals]),
            String(argument[argument.index(after: equals)...])
        )
    }

    /// The name as the sender wrote it, base64 or not.
    ///
    /// iTerm2 sends it base64-encoded; other senders send it plainly. Trying
    /// the decode and keeping the original when the result is not text handles
    /// both without asking the sender which it meant.
    private static func decodedName(_ value: String) -> String {
        guard let data = Data(base64Encoded: value),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty
        else {
            return value
        }
        return decoded
    }

    private static func extent(_ value: String) -> Extent {
        guard value != "auto", !value.isEmpty else {
            return .auto
        }

        if value.hasSuffix("px"), let pixels = Int(value.dropLast(2)) {
            return .pixels(min(max(pixels, 0), Limit.extentPIXELS))
        }
        if value.hasSuffix("%"), let percent = Int(value.dropLast(1)) {
            return .percent(min(max(percent, 1), 100))
        }
        guard let cells = Int(value) else {
            return .auto
        }
        return .cells(min(max(cells, 0), Limit.extentCELLS))
    }
}
