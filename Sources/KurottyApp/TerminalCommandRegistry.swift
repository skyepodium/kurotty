import AppKit

enum TerminalCommandCategory: String, CaseIterable {
    case tabs
    case panes
    case navigation
    case appearance
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
    case findTerminalOutput = "terminal.findOutput"
    case jumpToPreviousPrompt = "terminal.jumpToPreviousPrompt"
    case jumpToNextPrompt = "terminal.jumpToNextPrompt"
    case toggleCommandHistoryPanel = "history.togglePanel"
    case toggleFileExplorerPanel = "explorer.togglePanel"
    case toggleAgentSessionPanel = "sessions.togglePanel"
    case openProjectFile = "project.openFile"
    case openGettingStarted = "app.gettingStarted"
    case increaseFontSize = "terminal.increaseFontSize"
    case decreaseFontSize = "terminal.decreaseFontSize"
    case resetFontSize = "terminal.resetFontSize"
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
    case findTerminalOutput
    case jumpToPrompt(TerminalPromptRailNavigation.Direction)
    case toggleCommandHistoryPanel
    case toggleFileExplorerPanel
    case toggleAgentSessionPanel
    case openProjectFile
    case openGettingStarted
    case zoomFont(TerminalFontZoomStep)
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
        let flags = event.modifierFlags.terminalInputModifiers
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

    var displayLabel: String {
        var label = ""
        if modifiers.contains(.control) {
            label += "⌃"
        }
        if modifiers.contains(.option) {
            label += "⌥"
        }
        if modifiers.contains(.shift) {
            label += "⇧"
        }
        if modifiers.contains(.command) {
            label += "⌘"
        }

        if let keyEquivalent {
            label += keyEquivalent.uppercased()
        } else if let keyCode {
            label += keyCode.displayLabel
        }

        return label
    }
}

private extension UInt16 {
    var displayLabel: String {
        switch self {
        case 123:
            return "←"
        case 124:
            return "→"
        case 125:
            return "↓"
        case 126:
            return "↑"
        default:
            return "#\(self)"
        }
    }
}

enum TerminalCommandTooltip {
    static func text(
        for commandID: TerminalWindowCommandID,
        title overrideTitle: String? = nil,
        registry: TerminalCommandRegistry = .localized
    ) -> String {
        guard let command = registry.windowCommands.first(where: { $0.id == commandID }) else {
            return overrideTitle ?? ""
        }
        let title = overrideTitle ?? command.title
        guard let shortcut = command.shortcut else {
            return title
        }
        return "\(title) (\(shortcut.displayLabel))"
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
    /// User-authored quick commands already filtered for the active pane's
    /// working directory. Empty unless a surface registered them.
    let quickCommands: [TerminalQuickCommandRegistryEntry]

    init(
        windowCommands: [TerminalCommand],
        commandSpanCommands: [TerminalCommandSpanCommand] = [],
        quickCommands: [TerminalQuickCommandRegistryEntry] = []
    ) {
        self.windowCommands = windowCommands
        self.commandSpanCommands = commandSpanCommands
        self.quickCommands = quickCommands
    }

    /// Returns a copy of this registry carrying the quick commands visible in
    /// `workingDirectory`. Directory-scoped commands outside that directory are
    /// never registered, so they cannot appear in any surface.
    func registering(
        quickCommands: [QuickCommand],
        workingDirectory: String?,
        language: AppLanguage = .english
    ) -> TerminalCommandRegistry {
        TerminalCommandRegistry(
            windowCommands: windowCommands,
            commandSpanCommands: commandSpanCommands,
            quickCommands: QuickCommandPresentation.entries(
                for: quickCommands,
                workingDirectory: workingDirectory,
                language: language
            )
        )
    }

    func quickCommand(for id: String) -> QuickCommand? {
        quickCommands.first { $0.quickCommand.id == id }?.quickCommand
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

    /// Arrow key codes, matched by hardware code for the same reason the zoom
    /// keys are: a non-Latin input source reports no character for them.
    private enum ArrowKeyCode {
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// Matched by hardware key code rather than by character: on a US layout
    /// ⌘+ arrives as Shift+Equal, so a character match would need two entries
    /// for one command, and non-Latin input sources report neither character.
    private enum ZoomKeyCode {
        static let equal: UInt16 = 24
        static let minus: UInt16 = 27
        static let zero: UInt16 = 29
    }

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
            id: .findTerminalOutput,
            title: AppLocalization.string(.findTerminalOutput, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyEquivalent: "f", modifiers: .command),
            action: .findTerminalOutput,
            searchTokens: ["find text", "search output", "search scrollback", "terminal search"]
        ),
        // ⌘⇧↑ / ⌘⇧↓, matching iTerm2's Previous/Next Mark, which is the same
        // gesture over the same OSC 133 data. Ghostty and kitty bind their
        // `jump_to_prompt` / `scroll_to_prompt` to the bare ⌘-arrow and to
        // ⌃⇧Z/X respectively; the bare ⌘-arrow is already pane focus here, and
        // a letter pair would not read as movement. Shift is a required
        // modifier rather than a tolerated extra, which is exactly what keeps
        // this from shadowing `focusPaneUp` on the same key code.
        TerminalCommand(
            id: .jumpToPreviousPrompt,
            title: AppLocalization.string(.jumpToPreviousPrompt, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(
                keyCode: ArrowKeyCode.up,
                modifiers: [.command, .shift],
                allowedExtraModifiers: arrowShortcutExtras
            ),
            action: .jumpToPrompt(.previous),
            searchTokens: ["previous prompt", "previous command", "jump to prompt", "previous mark", "scroll to prompt"]
        ),
        TerminalCommand(
            id: .jumpToNextPrompt,
            title: AppLocalization.string(.jumpToNextPrompt, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(
                keyCode: ArrowKeyCode.down,
                modifiers: [.command, .shift],
                allowedExtraModifiers: arrowShortcutExtras
            ),
            action: .jumpToPrompt(.next),
            searchTokens: ["next prompt", "next command", "jump to prompt", "next mark", "scroll to prompt"]
        ),
        TerminalCommand(
            id: .toggleCommandHistoryPanel,
            title: AppLocalization.string(.commandHistory, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyEquivalent: "y", modifiers: [.command, .shift]),
            action: .toggleCommandHistoryPanel,
            searchTokens: ["command history", "history panel", "recent commands", "session list", "toggle history sidebar"]
        ),
        TerminalCommand(
            id: .toggleFileExplorerPanel,
            title: AppLocalization.string(.fileExplorer, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyEquivalent: "e", modifiers: [.command, .shift]),
            action: .toggleFileExplorerPanel,
            searchTokens: ["file explorer", "explorer panel", "file tree", "browse files", "toggle explorer sidebar"]
        ),
        TerminalCommand(
            id: .toggleAgentSessionPanel,
            title: AppLocalization.string(.agentSessions, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyEquivalent: "a", modifiers: [.command, .shift]),
            action: .toggleAgentSessionPanel,
            searchTokens: ["agent sessions", "ai sessions", "claude code sessions", "codex sessions", "resume session", "session vault"]
        ),
        TerminalCommand(
            id: .openProjectFile,
            title: AppLocalization.string(.openProjectFile, language: language),
            category: .navigation,
            // Command-P. Kurotty has no Print command to contest it, and it is
            // the chord every editor already trained people on.
            shortcut: TerminalCommandShortcut(keyEquivalent: "p", modifiers: .command),
            action: .openProjectFile,
            searchTokens: ["quick open", "go to file", "find file", "open file", "fuzzy file search", "file palette"]
        ),
        TerminalCommand(
            id: .openGettingStarted,
            title: AppLocalization.string(.gettingStarted, language: language),
            category: .navigation,
            // No shortcut. It is read once and then reached by name; a chord
            // spent on it would be a chord taken from something used daily.
            shortcut: nil,
            action: .openGettingStarted,
            searchTokens: ["getting started", "setup", "first run", "welcome", "onboarding", "what is set up"]
        ),
        TerminalCommand(
            id: .increaseFontSize,
            title: AppLocalization.string(.increaseFontSize, language: language),
            category: .appearance,
            shortcut: TerminalCommandShortcut(keyCode: ZoomKeyCode.equal, modifiers: .command, allowedExtraModifiers: .shift),
            action: .zoomFont(.increase),
            searchTokens: ["zoom in", "bigger text", "larger font", "font size up"]
        ),
        TerminalCommand(
            id: .decreaseFontSize,
            title: AppLocalization.string(.decreaseFontSize, language: language),
            category: .appearance,
            shortcut: TerminalCommandShortcut(keyCode: ZoomKeyCode.minus, modifiers: .command, allowedExtraModifiers: .shift),
            action: .zoomFont(.decrease),
            searchTokens: ["zoom out", "smaller text", "smaller font", "font size down"]
        ),
        TerminalCommand(
            id: .resetFontSize,
            title: AppLocalization.string(.resetFontSize, language: language),
            category: .appearance,
            shortcut: TerminalCommandShortcut(keyCode: ZoomKeyCode.zero, modifiers: .command, allowedExtraModifiers: .shift),
            action: .zoomFont(.reset),
            searchTokens: ["reset zoom", "actual size", "default font size", "restore font size"]
        ),
        TerminalCommand(
            id: .focusPaneLeft,
            title: AppLocalization.string(.focusPaneLeft, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: ArrowKeyCode.left, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.left),
            searchTokens: ["move left", "pane left", "go left", "previous pane"]
        ),
        TerminalCommand(
            id: .focusPaneRight,
            title: AppLocalization.string(.focusPaneRight, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: ArrowKeyCode.right, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.right),
            searchTokens: ["move right", "pane right", "go right", "next pane"]
        ),
        TerminalCommand(
            id: .focusPaneDown,
            title: AppLocalization.string(.focusPaneDown, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: ArrowKeyCode.down, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
            action: .focusPane(.down),
            searchTokens: ["move down", "pane down", "go down"]
        ),
        TerminalCommand(
            id: .focusPaneUp,
            title: AppLocalization.string(.focusPaneUp, language: language),
            category: .navigation,
            shortcut: TerminalCommandShortcut(keyCode: ArrowKeyCode.up, modifiers: .command, allowedExtraModifiers: arrowShortcutExtras),
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
