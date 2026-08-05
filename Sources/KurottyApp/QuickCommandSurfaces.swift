import AppKit

/// The seam between quick commands and the pane that receives their text.
///
/// Quick commands are surfaced by the palette, the context menu, and the
/// editor, none of which own a terminal pane. The window controller adopts
/// this protocol; nothing else in the feature may touch a pane.
@MainActor
protocol QuickCommandSendTarget: AnyObject {
    /// Working directory of the pane that would receive the text, used for
    /// directory-scope filtering. `nil` when no pane reports one.
    var quickCommandWorkingDirectory: String? { get }
    /// Writes already-approved bytes to the focused pane. Only
    /// `QuickCommandInvoker` may call this.
    func sendQuickCommandText(_ text: String)
}

/// Closure-backed target for tests and for call sites that already hold a
/// send closure instead of a controller.
@MainActor
final class QuickCommandClosureSendTarget: QuickCommandSendTarget {
    private let sendText: (String) -> Void
    private let workingDirectory: () -> String?

    init(
        workingDirectory: @escaping () -> String? = { nil },
        sendText: @escaping (String) -> Void
    ) {
        self.workingDirectory = workingDirectory
        self.sendText = sendText
    }

    var quickCommandWorkingDirectory: String? {
        workingDirectory()
    }

    func sendQuickCommandText(_ text: String) {
        sendText(text)
    }
}

/// The single entry point every quick-command surface uses.
///
/// Safety contract: this type never writes to a pane on its own. It hands the
/// command to `TerminalCommandDispatcher`, which decides whether the payload
/// may be sent, and only the dispatcher's handler forwards bytes to the target.
@MainActor
enum QuickCommandInvoker {
    /// A quick command the user authored and then triggered themselves does
    /// not need a per-invocation dialog, but it still has to pass the
    /// dispatcher's approval gate, exactly like command replay.
    @discardableResult
    static func invoke(
        _ command: QuickCommand,
        target: QuickCommandSendTarget,
        approval: QuickCommandApproval = QuickCommandApproval(isUserInitiated: true)
    ) -> QuickCommandDispatchResult {
        TerminalCommandDispatcher.execute(
            quickCommand: command,
            approval: approval,
            handlers: QuickCommandDispatchHandlers(
                sendText: { [weak target] text in
                    target?.sendQuickCommandText(text)
                }
            )
        )
    }
}

/// Palette/menu presentation metadata derived from a stored quick command.
struct TerminalQuickCommandRegistryEntry: Equatable {
    let quickCommand: QuickCommand
    let title: String
    let subtitle: String
    let paletteIdentifier: String
    let shortcutLabel: String?
    let executesOnDispatch: Bool
    let searchTokens: [String]
}

enum QuickCommandPresentation {
    /// Palette/menu title. An unnamed in-progress row falls back to its body
    /// text so it is still recognizable instead of showing as blank.
    static func title(for command: QuickCommand, language: AppLanguage = .english) -> String {
        let name = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        let body = command.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty else {
            return body
        }
        return AppLocalization.string(.quickCommandUntitled, language: language)
    }

    static func scopeDescription(
        for scope: QuickCommandScope,
        language: AppLanguage = .english
    ) -> String {
        switch scope {
        case .global:
            return AppLocalization.string(.quickCommandScopeGlobal, language: language)
        case let .directory(path):
            return String(
                format: AppLocalization.string(.quickCommandScopeDirectory, language: language),
                (path as NSString).lastPathComponent
            )
        }
    }

    static func subtitle(for command: QuickCommand, language: AppLanguage = .english) -> String {
        let scope = scopeDescription(for: command.scope, language: language)
        let safety = command.executesOnDispatch
            ? AppLocalization.string(.quickCommandRunsImmediately, language: language)
            : AppLocalization.string(.quickCommandInsertsOnly, language: language)
        return "\(scope) · \(safety)"
    }

    static func entry(
        for command: QuickCommand,
        language: AppLanguage = .english
    ) -> TerminalQuickCommandRegistryEntry {
        TerminalQuickCommandRegistryEntry(
            quickCommand: command,
            title: title(for: command, language: language),
            subtitle: subtitle(for: command, language: language),
            paletteIdentifier: AppConstants.QuickCommands.paletteIdentifierPrefix + command.id,
            shortcutLabel: command.keyboardShortcut,
            executesOnDispatch: command.executesOnDispatch,
            searchTokens: searchTokens(for: command, language: language)
        )
    }

    /// Registry entries for the commands visible in `workingDirectory`.
    static func entries(
        for commands: [QuickCommand],
        workingDirectory: String?,
        language: AppLanguage = .english
    ) -> [TerminalQuickCommandRegistryEntry] {
        QuickCommandNormalizer
            .visibleCommands(commands, inWorkingDirectory: workingDirectory)
            .map { entry(for: $0, language: language) }
    }

    private static func searchTokens(
        for command: QuickCommand,
        language: AppLanguage
    ) -> [String] {
        var tokens = [
            AppLocalization.string(.quickCommands, language: language),
            command.bodyText,
            scopeDescription(for: command.scope, language: language),
        ]
        switch command.action {
        case .terminalCommand:
            tokens.append(AppLocalization.string(.quickCommandActionTerminalCommand, language: language))
        case let .agentPrompt(_, agent):
            tokens.append(AppLocalization.string(.quickCommandActionAgentPrompt, language: language))
            if let agent {
                tokens.append(agent)
            }
        }
        if let path = command.scope.directoryPath {
            tokens.append(path)
        }
        return tokens.filter { !$0.isEmpty }
    }
}

/// Pure description of the terminal context menu's "Quick Commands" submenu.
/// The surface view turns this into an `NSMenu`; keeping it a value type lets
/// the ordering and filtering be asserted without AppKit.
struct QuickCommandContextSubmenuItem: Equatable {
    let quickCommandID: String
    let title: String
    let subtitle: String
    let executesOnDispatch: Bool
}

struct QuickCommandContextSubmenu: Equatable {
    let title: String
    let items: [QuickCommandContextSubmenuItem]

    var isEmpty: Bool {
        items.isEmpty
    }
}

enum QuickCommandContextMenuBuilder {
    /// Returns nil when nothing is visible for this working directory, so the
    /// menu never grows an empty submenu.
    static func submenu(
        for commands: [QuickCommand],
        workingDirectory: String?,
        language: AppLanguage = .english,
        limit: Int = AppConstants.QuickCommands.contextMenuCommandLimitCount
    ) -> QuickCommandContextSubmenu? {
        let items = QuickCommandPresentation
            .entries(for: commands, workingDirectory: workingDirectory, language: language)
            .filter { $0.quickCommand.isComplete }
            .prefix(max(0, limit))
            .map { entry in
                QuickCommandContextSubmenuItem(
                    quickCommandID: entry.quickCommand.id,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    executesOnDispatch: entry.executesOnDispatch
                )
            }
        guard !items.isEmpty else {
            return nil
        }
        return QuickCommandContextSubmenu(
            title: AppLocalization.string(.quickCommandsMenuTitle, language: language),
            items: Array(items)
        )
    }

    /// Ready-made `NSMenu` for the submenu description, so the surface view's
    /// integration is a single call. Each item carries its quick command id as
    /// `representedObject`.
    @MainActor
    static func makeMenu(
        for submenu: QuickCommandContextSubmenu,
        target: AnyObject?,
        action: Selector
    ) -> NSMenu {
        let menu = NSMenu(title: submenu.title)
        for item in submenu.items {
            let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
            menuItem.target = target
            menuItem.representedObject = item.quickCommandID
            menuItem.toolTip = item.subtitle
            menu.addItem(menuItem)
        }
        return menu
    }
}
