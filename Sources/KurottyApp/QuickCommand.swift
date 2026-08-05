import Foundation

/// Where a quick command is offered. Directory-scoped commands only surface
/// when the active pane's working directory is at or below `path`.
enum QuickCommandScope: Equatable {
    case global
    case directory(path: String)

    var directoryPath: String? {
        guard case let .directory(path) = self else {
            return nil
        }
        return path
    }
}

/// What a quick command writes.
///
/// `terminalCommand` is shell text; when `appendEnter` is true it *executes*
/// and therefore must be routed through `TerminalCommandDispatcher`.
/// `agentPrompt` is prompt text for a running agent TUI and never executes.
enum QuickCommandAction: Equatable {
    case terminalCommand(text: String, appendEnter: Bool)
    case agentPrompt(text: String, agent: String?)

    var rawValue: String {
        switch self {
        case .terminalCommand:
            return AppConstants.QuickCommands.terminalCommandActionRawValue
        case .agentPrompt:
            return AppConstants.QuickCommands.agentPromptActionRawValue
        }
    }

    var bodyText: String {
        switch self {
        case let .terminalCommand(text, _):
            return text
        case let .agentPrompt(text, _):
            return text
        }
    }

    /// True only for a terminal command that appends Return. This is the single
    /// predicate the dispatcher's approval gate keys off.
    var executesOnDispatch: Bool {
        guard case let .terminalCommand(_, appendEnter) = self else {
            return false
        }
        return appendEnter
    }
}

/// One user-authored named action that writes text into the focused pane.
struct QuickCommand: Equatable {
    var id: String
    var name: String
    var keyboardShortcut: String?
    var scope: QuickCommandScope
    var action: QuickCommandAction

    init(
        id: String,
        name: String,
        keyboardShortcut: String? = nil,
        scope: QuickCommandScope = .global,
        action: QuickCommandAction
    ) {
        self.id = id
        self.name = name
        self.keyboardShortcut = keyboardShortcut
        self.scope = scope
        self.action = action
    }

    var bodyText: String {
        action.bodyText
    }

    /// A row the user is still filling in is not complete, but it is still
    /// preserved by normalization so an in-progress edit is never dropped.
    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var executesOnDispatch: Bool {
        action.executesOnDispatch
    }
}

/// Wire record for `quick-commands.json`. Every field is optional so an
/// in-progress row written by the editor survives a reload, and so a field with
/// an unexpected type is treated as absent rather than failing the whole file.
struct QuickCommandScopeRecord: Codable, Equatable {
    var type: String?
    var path: String?

    init(type: String? = nil, path: String? = nil) {
        self.type = type
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        path = try? container.decodeIfPresent(String.self, forKey: .path)
    }
}

struct QuickCommandRecord: Codable, Equatable {
    var id: String?
    var name: String?
    var shortcut: String?
    var scope: QuickCommandScopeRecord?
    var action: String?
    var command: String?
    var appendEnter: Bool?
    var prompt: String?
    var agent: String?

    init(
        id: String? = nil,
        name: String? = nil,
        shortcut: String? = nil,
        scope: QuickCommandScopeRecord? = nil,
        action: String? = nil,
        command: String? = nil,
        appendEnter: Bool? = nil,
        prompt: String? = nil,
        agent: String? = nil
    ) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.scope = scope
        self.action = action
        self.command = command
        self.appendEnter = appendEnter
        self.prompt = prompt
        self.agent = agent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        shortcut = try? container.decodeIfPresent(String.self, forKey: .shortcut)
        scope = try? container.decodeIfPresent(QuickCommandScopeRecord.self, forKey: .scope)
        action = try? container.decodeIfPresent(String.self, forKey: .action)
        command = try? container.decodeIfPresent(String.self, forKey: .command)
        appendEnter = try? container.decodeIfPresent(Bool.self, forKey: .appendEnter)
        prompt = try? container.decodeIfPresent(String.self, forKey: .prompt)
        agent = try? container.decodeIfPresent(String.self, forKey: .agent)
    }
}

/// Versioned document envelope, matching the repo rule that user-editable
/// state is versioned JSON rather than scattered defaults keys.
struct QuickCommandsDocument: Codable, Equatable {
    var version: Int
    var commands: [QuickCommandRecord]

    init(version: Int = AppConstants.QuickCommands.storageSchemaVersion, commands: [QuickCommandRecord]) {
        self.version = version
        self.commands = commands
    }
}

/// Add/replace/remove applied one command at a time so a concurrent editor
/// session cannot silently drop commands it did not know about.
enum QuickCommandMutation: Equatable {
    case upsert(QuickCommand)
    case delete(id: String)
}
