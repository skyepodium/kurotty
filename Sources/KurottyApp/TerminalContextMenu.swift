import AppKit

enum TerminalContextMenuAction: Equatable {
    case copySelection
    case paste
    case splitRight
    case splitDown

    var iconSymbolName: String {
        switch self {
        case .copySelection:
            return "doc.on.doc"
        case .paste:
            return "doc.on.clipboard"
        case .splitRight:
            return "rectangle.split.2x1"
        case .splitDown:
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
        static let splitDown = "Split Down"
    }

    static func entries(for state: TerminalContextMenuState) -> [TerminalContextMenuEntry] {
        var entries: [TerminalContextMenuEntry] = []
        if state.hasSelection {
            entries.append(.item(title: Title.copy, action: .copySelection))
        }
        entries.append(.item(title: Title.paste, action: .paste, isEnabled: state.hasPasteboardText))
        entries.append(.separator)
        entries.append(.item(title: Title.splitRight, action: .splitRight))
        entries.append(.item(title: Title.splitDown, action: .splitDown))
        return entries
    }
}
