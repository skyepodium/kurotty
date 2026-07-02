import AppKit

enum TerminalCommandCategory: String, CaseIterable {
    case tabs
    case panes
    case navigation
}

enum TerminalWindowCommandID: String, CaseIterable {
    case newTab = "window.newTab"
    case splitVertically = "window.splitVertically"
    case splitHorizontally = "window.splitHorizontally"
    case closeCurrentPane = "window.closeCurrentPane"
    case focusPaneLeft = "window.focusPane.left"
    case focusPaneRight = "window.focusPane.right"
    case focusPaneUp = "window.focusPane.up"
    case focusPaneDown = "window.focusPane.down"
    case selectNextTab = "window.selectNextTab"
    case selectPreviousTab = "window.selectPreviousTab"
}

enum TerminalWindowCommandAction: Equatable {
    case newTab
    case splitVertically
    case splitHorizontally
    case closeCurrentPane
    case focusPane(TerminalPaneFocusDirection)
    case selectNextTab
    case selectPreviousTab
}

struct TerminalCommandShortcut: Equatable {
    let keyEquivalent: String?
    let keyCode: UInt16?
    let modifiers: NSEvent.ModifierFlags
    private let allowedExtraModifiers: NSEvent.ModifierFlags

    init(
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        allowedExtraModifiers: NSEvent.ModifierFlags = []
    ) {
        self.keyEquivalent = keyEquivalent
        self.keyCode = nil
        self.modifiers = modifiers
        self.allowedExtraModifiers = allowedExtraModifiers
    }

    init(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        allowedExtraModifiers: NSEvent.ModifierFlags = []
    ) {
        self.keyEquivalent = nil
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.allowedExtraModifiers = allowedExtraModifiers
    }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(modifiers),
              flags.subtracting(modifiers.union(allowedExtraModifiers)).isEmpty
        else {
            return false
        }

        if let keyCode {
            return event.keyCode == keyCode
        }

        guard let keyEquivalent,
              let characters = TerminalTextInputRouter.latinKeyEquivalent(for: event)
        else {
            return false
        }
        return characters == keyEquivalent
    }
}

struct TerminalCommand: Equatable {
    let id: TerminalWindowCommandID
    let title: String
    let category: TerminalCommandCategory
    let shortcut: TerminalCommandShortcut?
    let action: TerminalWindowCommandAction
    let searchTokens: [String]

    init(
        id: TerminalWindowCommandID,
        title: String,
        category: TerminalCommandCategory,
        shortcut: TerminalCommandShortcut?,
        action: TerminalWindowCommandAction,
        searchTokens: [String] = []
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.action = action
        self.searchTokens = searchTokens
    }
}

struct TerminalCommandRegistry {
    static let `default` = TerminalCommandRegistry(windowCommands: Self.defaultWindowCommands)

    let windowCommands: [TerminalCommand]

    func windowCommand(matching event: NSEvent) -> TerminalCommand? {
        windowCommands.first { command in
            command.shortcut?.matches(event) == true
        }
    }

    private static let arrowShortcutExtras: NSEvent.ModifierFlags = [.option, .numericPad, .function]

    private static let defaultWindowCommands: [TerminalCommand] = [
        TerminalCommand(
            id: .newTab,
            title: "New Tab",
            category: .tabs,
            shortcut: TerminalCommandShortcut(keyEquivalent: "t", modifiers: .command),
            action: .newTab,
            searchTokens: ["create tab", "open tab", "open another tab", "new window", "browser tab"]
        ),
        TerminalCommand(
            id: .splitVertically,
            title: "Split Vertically",
            category: .panes,
            shortcut: TerminalCommandShortcut(keyEquivalent: "d", modifiers: .command),
            action: .splitVertically,
            searchTokens: ["vertical split", "split right", "side by side", "two columns"]
        ),
        TerminalCommand(
            id: .splitHorizontally,
            title: "Split Horizontally",
            category: .panes,
            shortcut: TerminalCommandShortcut(keyEquivalent: "d", modifiers: [.command, .shift]),
            action: .splitHorizontally,
            searchTokens: ["horizontal split", "split down", "stacked panes", "two rows"]
        ),
        TerminalCommand(
            id: .closeCurrentPane,
            title: "Close Pane",
            category: .panes,
            shortcut: TerminalCommandShortcut(keyEquivalent: "w", modifiers: .command, allowedExtraModifiers: .shift),
            action: .closeCurrentPane,
            searchTokens: ["close current pane", "close tab", "close window", "remove pane"]
        ),
        TerminalCommand(
            id: .focusPaneLeft,
            title: "Focus Pane Left",
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: 123, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.left),
            searchTokens: ["move left", "pane left", "go left", "previous pane"]
        ),
        TerminalCommand(
            id: .focusPaneRight,
            title: "Focus Pane Right",
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: 124, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.right),
            searchTokens: ["move right", "pane right", "go right", "next pane"]
        ),
        TerminalCommand(
            id: .focusPaneDown,
            title: "Focus Pane Down",
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: 125, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.down),
            searchTokens: ["move down", "pane down", "go down"]
        ),
        TerminalCommand(
            id: .focusPaneUp,
            title: "Focus Pane Up",
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: 126, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.up),
            searchTokens: ["move up", "pane up", "go up"]
        ),
        TerminalCommand(
            id: .selectPreviousTab,
            title: "Previous Tab",
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyEquivalent: "[", modifiers: [.command, .shift]),
            action: .selectPreviousTab,
            searchTokens: ["previous window", "tab previous", "back tab"]
        ),
        TerminalCommand(
            id: .selectNextTab,
            title: "Next Tab",
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyEquivalent: "]", modifiers: [.command, .shift]),
            action: .selectNextTab,
            searchTokens: ["next window", "tab next", "forward tab"]
        ),
    ]
}
