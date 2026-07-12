import AppKit

enum TerminalCommandCategory: String, CaseIterable {
    case tabs
    case panes
    case navigation
    case tmux
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
    case tmuxSwapPanePrevious = "tmux.swapPane.previous"
    case tmuxSwapPaneNext = "tmux.swapPane.next"
    case tmuxRotateWindowPrevious = "tmux.rotateWindow.previous"
    case tmuxRotateWindowNext = "tmux.rotateWindow.next"
    case tmuxToggleZoom = "tmux.toggleZoom"
    case tmuxSelectNextLayout = "tmux.layout.next"
    case tmuxSelectPreviousLayout = "tmux.layout.previous"
    case tmuxEvenHorizontalLayout = "tmux.layout.evenHorizontal"
    case tmuxEvenVerticalLayout = "tmux.layout.evenVertical"
    case tmuxDetachClient = "tmux.detachClient"
}

enum TerminalWindowCommandAction: Equatable {
    case newTab
    case splitVertically
    case splitHorizontally
    case closeCurrentPane
    case focusPane(TerminalPaneFocusDirection)
    case selectNextTab
    case selectPreviousTab
    case tmuxSwapPane(TmuxPaneSwapDirection)
    case tmuxRotateWindow(TmuxRotationDirection)
    case tmuxToggleZoom
    case tmuxSelectLayout(TmuxLayoutSelection)
    case tmuxDetachClient
}

enum TerminalCommandSpanCommandID: String, CaseIterable {
    case foldOutput = "commandSpan.foldOutput"
    case copyReference = "commandSpan.copyReference"
    case replay = "commandSpan.replay"
}

enum TerminalCommandSpanAction: Equatable {
    case foldOutput
    case copyReference
    case replay
}

enum TerminalCommandSpanCategory: String, CaseIterable {
    case commandSpans
}

enum TerminalCommandApprovalPolicy: Equatable {
    case none
    case explicitUserConfirmation
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

struct TerminalCommandSpanCommand: Equatable {
    let id: TerminalCommandSpanCommandID
    let title: String
    let subtitle: String
    let category: TerminalCommandSpanCategory
    let action: TerminalCommandSpanAction
    let approvalPolicy: TerminalCommandApprovalPolicy
    let searchTokens: [String]

    init(
        id: TerminalCommandSpanCommandID,
        title: String,
        subtitle: String,
        category: TerminalCommandSpanCategory = .commandSpans,
        action: TerminalCommandSpanAction,
        approvalPolicy: TerminalCommandApprovalPolicy = .none,
        searchTokens: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.action = action
        self.approvalPolicy = approvalPolicy
        self.searchTokens = searchTokens
    }
}

struct TerminalCommandRegistry {
    static let `default` = TerminalCommandRegistry(
        windowCommands: Self.defaultWindowCommands,
        commandSpanCommands: Self.defaultCommandSpanCommands
    )

    static let tmuxControl = TerminalCommandRegistry(
        windowCommands: Self.defaultWindowCommands + Self.tmuxWindowCommands,
        commandSpanCommands: Self.defaultCommandSpanCommands
    )

    let windowCommands: [TerminalCommand]
    let commandSpanCommands: [TerminalCommandSpanCommand]

    init(
        windowCommands: [TerminalCommand],
        commandSpanCommands: [TerminalCommandSpanCommand] = []
    ) {
        self.windowCommands = windowCommands
        self.commandSpanCommands = commandSpanCommands
    }

    func windowCommand(matching event: NSEvent) -> TerminalCommand? {
        windowCommands.first { command in
            command.shortcut?.matches(event) == true
        }
    }

    func commandSpanCommand(for id: TerminalCommandSpanCommandID) -> TerminalCommandSpanCommand? {
        commandSpanCommands.first { command in
            command.id == id
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

    private static let tmuxWindowCommands: [TerminalCommand] = [
        TerminalCommand(id: .tmuxSwapPanePrevious, title: "Tmux: Swap Pane Previous", category: .tmux, shortcut: nil, action: .tmuxSwapPane(.previous), searchTokens: ["move pane backward", "swap tmux pane"]),
        TerminalCommand(id: .tmuxSwapPaneNext, title: "Tmux: Swap Pane Next", category: .tmux, shortcut: nil, action: .tmuxSwapPane(.next), searchTokens: ["move pane forward", "swap tmux pane"]),
        TerminalCommand(id: .tmuxRotateWindowPrevious, title: "Tmux: Rotate Panes Previous", category: .tmux, shortcut: nil, action: .tmuxRotateWindow(.previous), searchTokens: ["rotate tmux panes backward"]),
        TerminalCommand(id: .tmuxRotateWindowNext, title: "Tmux: Rotate Panes Next", category: .tmux, shortcut: nil, action: .tmuxRotateWindow(.next), searchTokens: ["rotate tmux panes forward"]),
        TerminalCommand(id: .tmuxToggleZoom, title: "Tmux: Toggle Pane Zoom", category: .tmux, shortcut: nil, action: .tmuxToggleZoom, searchTokens: ["maximize pane", "unzoom pane"]),
        TerminalCommand(id: .tmuxSelectNextLayout, title: "Tmux: Next Layout", category: .tmux, shortcut: nil, action: .tmuxSelectLayout(.next), searchTokens: ["cycle tmux layout"]),
        TerminalCommand(id: .tmuxSelectPreviousLayout, title: "Tmux: Previous Layout", category: .tmux, shortcut: nil, action: .tmuxSelectLayout(.previous), searchTokens: ["previous tmux layout"]),
        TerminalCommand(id: .tmuxEvenHorizontalLayout, title: "Tmux: Even Horizontal Layout", category: .tmux, shortcut: nil, action: .tmuxSelectLayout(.evenHorizontal), searchTokens: ["balance tmux columns"]),
        TerminalCommand(id: .tmuxEvenVerticalLayout, title: "Tmux: Even Vertical Layout", category: .tmux, shortcut: nil, action: .tmuxSelectLayout(.evenVertical), searchTokens: ["balance tmux rows"]),
        TerminalCommand(id: .tmuxDetachClient, title: "Tmux: Detach Client", category: .tmux, shortcut: nil, action: .tmuxDetachClient, searchTokens: ["leave tmux session", "disconnect tmux"]),
    ]

    private static let defaultCommandSpanCommands: [TerminalCommandSpanCommand] = [
        TerminalCommandSpanCommand(
            id: .foldOutput,
            title: "Fold Command Output",
            subtitle: "Collapse a completed command's output while keeping the command reference.",
            action: .foldOutput,
            searchTokens: ["collapse command output", "hide command output", "toggle command output"]
        ),
        TerminalCommandSpanCommand(
            id: .copyReference,
            title: "Copy Command Reference",
            subtitle: "Copy a stable command-span reference without including raw output.",
            action: .copyReference,
            searchTokens: ["copy span reference", "copy command id", "copy command link"]
        ),
        TerminalCommandSpanCommand(
            id: .replay,
            title: "Replay Command",
            subtitle: "Run the captured command again after explicit confirmation.",
            action: .replay,
            approvalPolicy: .explicitUserConfirmation,
            searchTokens: ["rerun command", "run command again", "repeat command", "rerun safely"]
        ),
    ]
}
