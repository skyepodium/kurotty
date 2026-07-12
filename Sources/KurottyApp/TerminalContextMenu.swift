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
    static func entries(for state: TerminalContextMenuState, language: AppLanguage = .english) -> [TerminalContextMenuEntry] {
        var entries: [TerminalContextMenuEntry] = []
        if state.hasSelection {
            entries.append(.item(title: AppLocalization.string(.copy, language: language), action: .copySelection))
        }
        entries.append(.item(title: AppLocalization.string(.paste, language: language), action: .paste, isEnabled: state.hasPasteboardText))
        entries.append(.separator)
        entries.append(.item(title: AppLocalization.string(.splitRight, language: language), action: .split(.right)))
        entries.append(.item(title: AppLocalization.string(.splitLeft, language: language), action: .split(.left)))
        entries.append(.item(title: AppLocalization.string(.splitDown, language: language), action: .split(.down)))
        entries.append(.item(title: AppLocalization.string(.splitUp, language: language), action: .split(.up)))
        return entries
    }
}
