import Foundation

/// Agent hook events Kurotty maps onto agent activity states.
///
/// Only lifecycle events are used. Kurotty never installs a hook on tool use,
/// so no prompt, tool argument, or transcript content is observed.
///
/// Not every agent emits every event: the set an agent actually gets is
/// `AgentStatusHookTarget.events`.
enum AgentStatusHookEvent: String, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case notification = "Notification"
    case stop = "Stop"

    var reportedState: AgentActivityState {
        switch self {
        case .userPromptSubmit:
            return .working
        case .notification:
            return .waitingForInput
        case .stop:
            return .done
        }
    }
}

/// An agent whose on-disk hook configuration Kurotty can manage.
///
/// Claude Code and Codex use the same document shape, so one installer serves
/// both. What differs is the file, the events the agent emits, the name
/// reported for the pane, and how much of the surrounding document Kurotty is
/// willing to rewrite.
enum AgentStatusHookTarget: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    var configurationRelativePath: String {
        switch self {
        case .claudeCode:
            return AppConstants.AgentStatus.claudeSettingsRelativePath
        case .codex:
            return AppConstants.AgentStatus.codexHooksRelativePath
        }
    }

    /// Product name, for the consent prompt. Not localized: it is a name.
    var productName: String {
        switch self {
        case .claudeCode:
            return AppConstants.AgentStatus.claudeProductName
        case .codex:
            return AppConstants.AgentStatus.codexProductName
        }
    }

    /// The `agent` field of the reported status, which is what the pane shows.
    var reportedAgentName: String {
        switch self {
        case .claudeCode:
            return AppConstants.AgentStatus.claudeReportedAgentName
        case .codex:
            return AppConstants.AgentStatus.codexReportedAgentName
        }
    }

    /// Events Kurotty installs for this agent.
    ///
    /// Codex has no counterpart to Claude Code's `Notification`, so nothing it
    /// emits means "the agent is waiting for you". Its `PreToolUse` fires for
    /// every tool call whether or not approval is required, so reading it as
    /// `waitingForInput` would report a state the agent is usually not in.
    /// Kurotty therefore leaves `waitingForInput` unreported for Codex rather
    /// than approximating it; over OSC 9999 a producer can still send it.
    var events: [AgentStatusHookEvent] {
        switch self {
        case .claudeCode:
            return [.userPromptSubmit, .notification, .stop]
        case .codex:
            return [.userPromptSubmit, .stop]
        }
    }

    /// Top-level keys the agent accepts, or `nil` when Kurotty imposes no
    /// restriction. See `AppConstants.AgentStatus.codexPermittedTopLevelKeys`
    /// for why Codex has one.
    var permittedTopLevelKeys: Set<String>? {
        switch self {
        case .claudeCode:
            return nil
        case .codex:
            return AppConstants.AgentStatus.codexPermittedTopLevelKeys
        }
    }

    /// Directory that has to exist before Kurotty will write this agent's
    /// configuration at all, or `nil` when the file may be created from nothing.
    var requiredConfigurationDirectoryRelativePath: String? {
        switch self {
        case .claudeCode:
            return nil
        case .codex:
            return AppConstants.AgentStatus.codexConfigurationDirectoryRelativePath
        }
    }

    /// Whether this agent's configuration may be touched on this machine.
    func isInstallable(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let relativePath = requiredConfigurationDirectoryRelativePath else {
            return true
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: homeDirectory.appendingPathComponent(relativePath).path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }
}

/// Installation of agent hooks so agent status works even when the agent does
/// not emit the OSC 9999 channel.
///
/// This modifies files Kurotty does not own — `~/.claude/settings.json` and
/// `~/.codex/hooks.json`. It is gated by `terminal.agentStatusHooksEnabled`,
/// which defaults to `true`, and by the per-agent consent in
/// `AgentStatusHookConsentPolicy` — the default states intent, the consent is
/// what permits the write.
///
/// Contract:
/// - Every other key in the file is preserved byte-for-value; only Kurotty's
///   own hook entries are added or removed.
/// - Kurotty's entries are identified by `managedCommandMarker` inside the
///   command string, so uninstall can never remove a user's hook.
/// - The previous file is copied to `<name>.kurotty-backup` before any write.
/// - A document Kurotty cannot fully recognize — unreadable, not JSON, not an
///   object, or carrying a top-level key the agent itself does not accept — is
///   reported and left byte-identical. `~/.codex/hooks.json` is commonly owned
///   by third-party tooling, and losing someone else's hooks to a repair
///   Kurotty guessed at is worse than reporting no status.
/// - The generated command sends a fixed JSON body built from environment
///   variables Kurotty injected. The agent's hook stdin payload is ignored and
///   never forwarded, so no prompt or transcript content leaves the agent.
/// - Every failure is returned, never thrown past the caller and never fatal.
enum AgentStatusHookInstaller {
    enum InstallError: Error, Equatable {
        case settingsFileUnreadable(String)
        case settingsFileNotJSONObject
        case settingsFileUnwritable(String)
        case backupFailed(String)
        case unrecognizedConfigurationShape(path: String, unrecognizedKeys: [String])

        var diagnostic: String {
            switch self {
            case .settingsFileUnreadable(let path):
                return "Kurotty agent status hooks: cannot read \(path)"
            case .settingsFileNotJSONObject:
                return "Kurotty agent status hooks: settings file is not a JSON object"
            case .settingsFileUnwritable(let path):
                return "Kurotty agent status hooks: cannot write \(path)"
            case .unrecognizedConfigurationShape(let path, let unrecognizedKeys):
                return "Kurotty agent status hooks: \(path) carries top-level keys the agent does not accept"
                    + " (\(unrecognizedKeys.joined(separator: ", "))); leaving it untouched"
            case .backupFailed(let path):
                return "Kurotty agent status hooks: cannot back up \(path)"
            }
        }
    }

    static func configurationFileURL(
        for target: AgentStatusHookTarget = .claudeCode,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent(target.configurationRelativePath)
    }

    static func backupFileURL(
        for target: AgentStatusHookTarget = .claudeCode,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        backupFileURL(forConfigurationAt: configurationFileURL(for: target, homeDirectory: homeDirectory))
    }

    /// One place decides where a backup lands, so the file `rewrite` writes and
    /// the file a caller looks for can never disagree.
    static func backupFileURL(forConfigurationAt fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(
            fileURL.lastPathComponent + AppConstants.AgentStatus.backupFileNameSuffix
        )
    }

    // MARK: - Command generation

    /// Shell command written into the hook entry.
    ///
    /// It no-ops unless Kurotty injected the PTY environment, so the entry is
    /// inert in any other terminal. The trailing marker comment is what makes
    /// the entry removable.
    static func command(for event: AgentStatusHookEvent, target: AgentStatusHookTarget = .claudeCode) -> String {
        let paneVariable = "$\(AppConstants.AgentStatus.paneIdentifierEnvironmentName)"
        let portVariable = "$\(AppConstants.AgentStatus.hookPortEnvironmentName)"
        let tokenVariable = "$\(AppConstants.AgentStatus.hookTokenEnvironmentName)"
        let url = "http://\(AppConstants.AgentStatus.hookLoopbackHost):\(portVariable)"
            + AppConstants.AgentStatus.hookRequestPath
        let body = #"{\"paneId\":\""# + paneVariable + #"\",\"state\":\""# + event.reportedState.rawValue
            + #"\",\"agent\":\""# + target.reportedAgentName + #"\"}"#
        let guardClause = "[ -n \"\(portVariable)\" ] && [ -n \"\(paneVariable)\" ] || exit 0"
        let post = [
            AppConstants.AgentStatus.hookCurlExecutablePath,
            "-s",
            "-m \(AppConstants.AgentStatus.hookRequestTimeoutSeconds)",
            "-o /dev/null",
            "-X POST",
            "-H 'Content-Type: application/json'",
            "-H \"\(AppConstants.AgentStatus.hookTokenHeaderName): \(tokenVariable)\"",
            "-d \"\(body)\"",
            "\"\(url)\"",
        ].joined(separator: " ")
        return "\(guardClause); \(post) || true # \(AppConstants.AgentStatus.managedCommandMarker)"
    }

    static func isManagedCommand(_ command: String) -> Bool {
        command.contains(AppConstants.AgentStatus.managedCommandMarker)
    }

    // MARK: - Pure JSON transforms

    /// Adds Kurotty's entries to a decoded settings object, replacing any
    /// previously managed entry and leaving every other key untouched.
    static func installing(
        into settings: [String: Any],
        target: AgentStatusHookTarget = .claudeCode
    ) -> [String: Any] {
        var next = removingKurottyEntries(from: settings)
        var hooks = next[AppConstants.AgentStatus.hookDocumentHooksKey] as? [String: Any] ?? [:]
        for event in target.events {
            var matchers = hooks[event.rawValue] as? [[String: Any]] ?? []
            matchers.append([
                AppConstants.AgentStatus.hookDocumentEntryListKey: [
                    [
                        AppConstants.AgentStatus.hookDocumentTypeKey:
                            AppConstants.AgentStatus.hookDocumentCommandType,
                        AppConstants.AgentStatus.hookDocumentCommandKey: command(for: event, target: target),
                    ],
                ],
            ])
            hooks[event.rawValue] = matchers
        }
        next[AppConstants.AgentStatus.hookDocumentHooksKey] = hooks
        return next
    }

    /// Removes only entries carrying Kurotty's marker. Empty containers left
    /// behind by the removal are pruned so the file does not accumulate husks.
    ///
    /// Target-agnostic on purpose: the marker identifies Kurotty's entries no
    /// matter which agent's file they landed in, so an entry written by an
    /// older build with a different event set still comes out.
    static func removingKurottyEntries(from settings: [String: Any]) -> [String: Any] {
        var next = settings
        guard var hooks = next[AppConstants.AgentStatus.hookDocumentHooksKey] as? [String: Any] else {
            return next
        }
        for (eventName, value) in hooks {
            guard let matchers = value as? [[String: Any]] else {
                continue
            }
            let cleanedMatchers = matchers.compactMap { matcher -> [String: Any]? in
                guard let entries = matcher[AppConstants.AgentStatus.hookDocumentEntryListKey] as? [[String: Any]]
                else {
                    return matcher
                }
                let keptEntries = entries.filter { entry in
                    guard let command = entry[AppConstants.AgentStatus.hookDocumentCommandKey] as? String else {
                        return true
                    }
                    return !isManagedCommand(command)
                }
                guard !keptEntries.isEmpty else {
                    return nil
                }
                var cleaned = matcher
                cleaned[AppConstants.AgentStatus.hookDocumentEntryListKey] = keptEntries
                return cleaned
            }
            if cleanedMatchers.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = cleanedMatchers
            }
        }
        if hooks.isEmpty {
            next.removeValue(forKey: AppConstants.AgentStatus.hookDocumentHooksKey)
        } else {
            next[AppConstants.AgentStatus.hookDocumentHooksKey] = hooks
        }
        return next
    }

    static func containsKurottyEntries(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings[AppConstants.AgentStatus.hookDocumentHooksKey] as? [String: Any] else {
            return false
        }
        for value in hooks.values {
            guard let matchers = value as? [[String: Any]] else {
                continue
            }
            for matcher in matchers {
                guard let entries = matcher[AppConstants.AgentStatus.hookDocumentEntryListKey] as? [[String: Any]]
                else {
                    continue
                }
                for entry in entries {
                    guard let command = entry[AppConstants.AgentStatus.hookDocumentCommandKey] as? String else {
                        continue
                    }
                    if isManagedCommand(command) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Top-level keys the agent would reject, sorted. Empty when the document
    /// is one Kurotty may rewrite.
    static func unrecognizedTopLevelKeys(
        in settings: [String: Any],
        target: AgentStatusHookTarget
    ) -> [String] {
        guard let permitted = target.permittedTopLevelKeys else {
            return []
        }
        return settings.keys.filter { !permitted.contains($0) }.sorted()
    }

    // MARK: - File I/O

    /// Installs Kurotty's hook entries. Fails soft: a missing directory, an
    /// unreadable file, or malformed JSON returns an error the caller can log.
    @discardableResult
    static func install(
        for target: AgentStatusHookTarget = .claudeCode,
        at fileURL: URL? = nil
    ) -> Result<Void, InstallError> {
        let destination = fileURL ?? configurationFileURL(for: target)
        return rewrite(fileURL: destination, target: target) { installing(into: $0, target: target) }
    }

    /// Removes Kurotty's hook entries, leaving everything else in place.
    @discardableResult
    static func uninstall(
        for target: AgentStatusHookTarget = .claudeCode,
        at fileURL: URL? = nil
    ) -> Result<Void, InstallError> {
        let destination = fileURL ?? configurationFileURL(for: target)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return .success(())
        }
        return rewrite(fileURL: destination, target: target, transform: removingKurottyEntries(from:))
    }

    private static func rewrite(
        fileURL: URL,
        target: AgentStatusHookTarget,
        transform: ([String: Any]) -> [String: Any]
    ) -> Result<Void, InstallError> {
        let fileManager = FileManager.default
        var settings: [String: Any] = [:]
        if fileManager.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL) else {
                return .failure(.settingsFileUnreadable(fileURL.path))
            }
            if !data.isEmpty {
                guard let decoded = try? JSONSerialization.jsonObject(with: data) else {
                    return .failure(.settingsFileUnreadable(fileURL.path))
                }
                guard let object = decoded as? [String: Any] else {
                    return .failure(.settingsFileNotJSONObject)
                }
                settings = object
            }
            // Checked before the backup so a document Kurotty refuses to touch
            // does not even gain a stray `.kurotty-backup` beside it. The same
            // rule applies to uninstall: entries left behind by a refusal are
            // inert outside Kurotty, which is a smaller cost than rewriting a
            // document whose shape we do not understand.
            let unrecognizedKeys = unrecognizedTopLevelKeys(in: settings, target: target)
            guard unrecognizedKeys.isEmpty else {
                return .failure(.unrecognizedConfigurationShape(
                    path: fileURL.path,
                    unrecognizedKeys: unrecognizedKeys
                ))
            }
            let backupURL = backupFileURL(forConfigurationAt: fileURL)
            try? fileManager.removeItem(at: backupURL)
            guard (try? fileManager.copyItem(at: fileURL, to: backupURL)) != nil else {
                return .failure(.backupFailed(fileURL.path))
            }
        } else {
            let directory = fileURL.deletingLastPathComponent()
            guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
                return .failure(.settingsFileUnwritable(fileURL.path))
            }
        }

        let updated = transform(settings)
        guard let data = try? JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return .failure(.settingsFileUnwritable(fileURL.path))
        }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else {
            return .failure(.settingsFileUnwritable(fileURL.path))
        }
        return .success(())
    }
}

/// Resolves whether the user wants hooks at all.
///
/// The setting lives at `terminal.agentStatusHooksEnabled` and defaults to
/// `true`. Wanting them is not permission to edit an agent's configuration:
/// that answer lives per agent in `AgentStatusHookConsentPolicy`, and both have
/// to agree before anything is written.
enum AgentStatusHookSettings {
    static let settingsKeyPath = AppConstants.AgentStatus.settingsKeyPath
    static let defaultValue = AppConstants.AgentStatus.hooksEnabledDefault

    /// A settings file that predates the key yields `nil` and takes the default.
    static func isEnabled(decodedSettingValue: Bool? = nil) -> Bool {
        decodedSettingValue ?? defaultValue
    }
}
