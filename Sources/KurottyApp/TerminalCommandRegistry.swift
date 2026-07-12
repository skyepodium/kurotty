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
    static var `default`: TerminalCommandRegistry { registry(language: .english) }
    static var localized: TerminalCommandRegistry { registry(language: AppLocalization.language) }

    static var tmuxControl: TerminalCommandRegistry { tmuxRegistry(language: .english) }
    static var localizedTmuxControl: TerminalCommandRegistry { tmuxRegistry(language: AppLocalization.language) }

    private static func registry(language: AppLanguage) -> TerminalCommandRegistry {
        TerminalCommandRegistry(windowCommands: defaultWindowCommands(language: language), commandSpanCommands: defaultCommandSpanCommands(language: language))
    }

    private static func tmuxRegistry(language: AppLanguage) -> TerminalCommandRegistry {
        TerminalCommandRegistry(windowCommands: defaultWindowCommands(language: language) + tmuxWindowCommands(language: language), commandSpanCommands: defaultCommandSpanCommands(language: language))
    }

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

    private static func defaultWindowCommands(language: AppLanguage) -> [TerminalCommand] { [
        TerminalCommand(
            id: .newTab,
            title: AppLocalization.string(.newTab, language: language),
            category: .tabs,
            shortcut: TerminalCommandShortcut(keyEquivalent: "t", modifiers: .command),
            action: .newTab,
            searchTokens: ["create tab", "open tab", "open another tab", "new window", "browser tab"]
        ),
        TerminalCommand(
            id: .splitVertically,
            title: AppLocalization.string(.splitVertically, language: language),
            category: .panes,
            shortcut: TerminalCommandShortcut(keyEquivalent: "d", modifiers: .command),
            action: .splitVertically,
            searchTokens: ["vertical split", "split right", "side by side", "two columns"]
        ),
        TerminalCommand(
            id: .splitHorizontally,
            title: AppLocalization.string(.splitHorizontally, language: language),
            category: .panes,
            shortcut: TerminalCommandShortcut(keyEquivalent: "d", modifiers: [.command, .shift]),
            action: .splitHorizontally,
            searchTokens: ["horizontal split", "split down", "stacked panes", "two rows"]
        ),
        TerminalCommand(
            id: .closeCurrentPane,
            title: AppLocalization.string(.closePane, language: language),
            category: .panes,
            shortcut: TerminalCommandShortcut(keyEquivalent: "w", modifiers: .command, allowedExtraModifiers: .shift),
            action: .closeCurrentPane,
            searchTokens: ["close current pane", "close tab", "close window", "remove pane"]
        ),
        TerminalCommand(
            id: .focusPaneLeft,
            title: AppLocalization.string(.focusPaneLeft, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: 123, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.left),
            searchTokens: ["move left", "pane left", "go left", "previous pane"]
        ),
        TerminalCommand(
            id: .focusPaneRight,
            title: AppLocalization.string(.focusPaneRight, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: 124, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.right),
            searchTokens: ["move right", "pane right", "go right", "next pane"]
        ),
        TerminalCommand(
            id: .focusPaneDown,
            title: AppLocalization.string(.focusPaneDown, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: 125, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.down),
            searchTokens: ["move down", "pane down", "go down"]
        ),
        TerminalCommand(
            id: .focusPaneUp,
            title: AppLocalization.string(.focusPaneUp, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: 126, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.up),
            searchTokens: ["move up", "pane up", "go up"]
        ),
        TerminalCommand(
            id: .selectPreviousTab,
            title: AppLocalization.string(.previousTab, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyEquivalent: "[", modifiers: [.command, .shift]),
            action: .selectPreviousTab,
            searchTokens: ["previous window", "tab previous", "back tab"]
        ),
        TerminalCommand(
            id: .selectNextTab,
            title: AppLocalization.string(.nextTab, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyEquivalent: "]", modifiers: [.command, .shift]),
            action: .selectNextTab,
            searchTokens: ["next window", "tab next", "forward tab"]
        ),
    ] }

    private static func tmuxWindowCommands(language: AppLanguage) -> [TerminalCommand] { [
        TerminalCommand(id: .tmuxSwapPanePrevious, title: AppLocalization.string(.tmuxSwapPanePrevious, language: language), category: .tmux, shortcut: nil, action: .tmuxSwapPane(.previous), searchTokens: ["move pane backward", "swap tmux pane"]),
        TerminalCommand(id: .tmuxSwapPaneNext, title: AppLocalization.string(.tmuxSwapPaneNext, language: language), category: .tmux, shortcut: nil, action: .tmuxSwapPane(.next), searchTokens: ["move pane forward", "swap tmux pane"]),
        TerminalCommand(id: .tmuxRotateWindowPrevious, title: AppLocalization.string(.tmuxRotatePanesPrevious, language: language), category: .tmux, shortcut: nil, action: .tmuxRotateWindow(.previous), searchTokens: ["rotate tmux panes backward"]),
        TerminalCommand(id: .tmuxRotateWindowNext, title: AppLocalization.string(.tmuxRotatePanesNext, language: language), category: .tmux, shortcut: nil, action: .tmuxRotateWindow(.next), searchTokens: ["rotate tmux panes forward"]),
        TerminalCommand(id: .tmuxToggleZoom, title: AppLocalization.string(.tmuxTogglePaneZoom, language: language), category: .tmux, shortcut: nil, action: .tmuxToggleZoom, searchTokens: ["maximize pane", "unzoom pane"]),
        TerminalCommand(id: .tmuxSelectNextLayout, title: AppLocalization.string(.tmuxNextLayout, language: language), category: .tmux, shortcut: nil, action: .tmuxSelectLayout(.next), searchTokens: ["cycle tmux layout"]),
        TerminalCommand(id: .tmuxSelectPreviousLayout, title: AppLocalization.string(.tmuxPreviousLayout, language: language), category: .tmux, shortcut: nil, action: .tmuxSelectLayout(.previous), searchTokens: ["previous tmux layout"]),
        TerminalCommand(id: .tmuxEvenHorizontalLayout, title: AppLocalization.string(.tmuxEvenHorizontalLayout, language: language), category: .tmux, shortcut: nil, action: .tmuxSelectLayout(.evenHorizontal), searchTokens: ["balance tmux columns"]),
        TerminalCommand(id: .tmuxEvenVerticalLayout, title: AppLocalization.string(.tmuxEvenVerticalLayout, language: language), category: .tmux, shortcut: nil, action: .tmuxSelectLayout(.evenVertical), searchTokens: ["balance tmux rows"]),
        TerminalCommand(id: .tmuxDetachClient, title: AppLocalization.string(.tmuxDetachClient, language: language), category: .tmux, shortcut: nil, action: .tmuxDetachClient, searchTokens: ["leave tmux session", "disconnect tmux"]),
    ] }

    private static func defaultCommandSpanCommands(language: AppLanguage) -> [TerminalCommandSpanCommand] { [
        TerminalCommandSpanCommand(
            id: .foldOutput,
            title: AppLocalization.string(.foldCommandOutput, language: language),
            subtitle: AppLocalization.string(.foldCommandOutputSubtitle, language: language),
            action: .foldOutput,
            searchTokens: ["collapse command output", "hide command output", "toggle command output"]
        ),
        TerminalCommandSpanCommand(
            id: .copyReference,
            title: AppLocalization.string(.copyCommandReference, language: language),
            subtitle: AppLocalization.string(.copyCommandReferenceSubtitle, language: language),
            action: .copyReference,
            searchTokens: ["copy span reference", "copy command id", "copy command link"]
        ),
        TerminalCommandSpanCommand(
            id: .replay,
            title: AppLocalization.string(.replayCommand, language: language),
            subtitle: AppLocalization.string(.replayCommandSubtitle, language: language),
            action: .replay,
            approvalPolicy: .explicitUserConfirmation,
            searchTokens: ["rerun command", "run command again", "repeat command", "rerun safely"]
        ),
    ] }
}
