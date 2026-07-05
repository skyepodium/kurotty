import AppKit

enum TerminalPaneSplitDirection: Equatable {
    case right
    case left
    case down
    case up

    var axis: NSLayoutConstraint.Orientation {
        switch self {
        case .right, .left:
            return .vertical
        case .down, .up:
            return .horizontal
        }
    }

    var insertsAfterActivePane: Bool {
        switch self {
        case .right, .down:
            return true
        case .left, .up:
            return false
        }
    }
}

enum TerminalContextMenuAction: Equatable {
    case copySelection
    case paste
    case split(TerminalPaneSplitDirection)

    var splitDirection: TerminalPaneSplitDirection? {
        guard case let .split(direction) = self else {
            return nil
        }
        return direction
    }

    var iconSymbolName: String {
        switch self {
        case .copySelection:
            return "doc.on.doc"
        case .paste:
            return "doc.on.clipboard"
        case .split(.right), .split(.left):
            return "rectangle.split.2x1"
        case .split(.down), .split(.up):
            return "rectangle.split.1x2"
        }
    }
}

struct TerminalContextMenuState: Equatable {
    let hasSelection: Bool
    let hasPasteboardText: Bool
}

struct TerminalContextMenuEntry: Equatable {
    let title: String?
    let action: TerminalContextMenuAction?
    let isEnabled: Bool
    let iconSymbolName: String?

    static func item(
        title: String,
        action: TerminalContextMenuAction,
        isEnabled: Bool = true
    ) -> TerminalContextMenuEntry {
        TerminalContextMenuEntry(
            title: title,
            action: action,
            isEnabled: isEnabled,
            iconSymbolName: action.iconSymbolName
        )
    }

    static let separator = TerminalContextMenuEntry(
        title: nil,
        action: nil,
        isEnabled: false,
        iconSymbolName: nil
    )
}

enum TerminalContextMenuBuilder {
    private enum Title {
        static let copy = "Copy"
        static let paste = "Paste"
        static let splitRight = "Split Right"
        static let splitLeft = "Split Left"
        static let splitDown = "Split Down"
        static let splitUp = "Split Up"
    }

    static func entries(for state: TerminalContextMenuState) -> [TerminalContextMenuEntry] {
        var entries: [TerminalContextMenuEntry] = []
        if state.hasSelection {
            entries.append(.item(title: Title.copy, action: .copySelection))
        }
        entries.append(.item(title: Title.paste, action: .paste, isEnabled: state.hasPasteboardText))
        entries.append(.separator)
        entries.append(.item(title: Title.splitRight, action: .split(.right)))
        entries.append(.item(title: Title.splitLeft, action: .split(.left)))
        entries.append(.item(title: Title.splitDown, action: .split(.down)))
        entries.append(.item(title: Title.splitUp, action: .split(.up)))
        return entries
    }
}
