import Foundation

/// Claude Code hook events Kurotty maps onto agent activity states.
///
/// Only lifecycle events are used. Kurotty never installs a hook on tool use,
/// so no prompt, tool argument, or transcript content is observed.
enum AgentStatusHookEvent: String, CaseIterable, Sendable {
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

/// Opt-in installation of Claude Code hooks so agent status works even when the
/// agent does not emit the OSC 9999 channel.
///
/// This modifies a file Kurotty does not own (`~/.claude/settings.json`), so it
/// is gated by `terminal.agentStatusHooksEnabled`, which defaults to `false`.
///
/// Contract:
/// - Every other key in the file is preserved byte-for-value; only Kurotty's
///   own hook entries are added or removed.
/// - Kurotty's entries are identified by `managedCommandMarker` inside the
///   command string, so uninstall can never remove a user's hook.
/// - The previous file is copied to `settings.json.kurotty-backup` before any
///   write.
/// - The generated command sends a fixed JSON body built from environment
///   variables Kurotty injected. Claude Code's hook stdin payload is ignored
///   and never forwarded, so no prompt or transcript content leaves the agent.
/// - Every failure is returned, never thrown past the caller and never fatal.
enum AgentStatusHookInstaller {
    enum InstallError: Error, Equatable {
        case settingsFileUnreadable(String)
        case settingsFileNotJSONObject
        case settingsFileUnwritable(String)
        case backupFailed(String)

        var diagnostic: String {
            switch self {
            case .settingsFileUnreadable(let path):
                return "Kurotty agent status hooks: cannot read \(path)"
            case .settingsFileNotJSONObject:
                return "Kurotty agent status hooks: settings file is not a JSON object"
            case .settingsFileUnwritable(let path):
                return "Kurotty agent status hooks: cannot write \(path)"
            case .backupFailed(let path):
                return "Kurotty agent status hooks: cannot back up \(path)"
            }
        }
    }

    static func settingsFileURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(AppConstants.AgentStatus.claudeSettingsRelativePath)
    }

    static func backupFileURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(AppConstants.AgentStatus.claudeSettingsBackupRelativePath)
    }

    // MARK: - Command generation

    /// Shell command written into the hook entry.
    ///
    /// It no-ops unless Kurotty injected the PTY environment, so the entry is
    /// inert in any other terminal. The trailing marker comment is what makes
    /// the entry removable.
    static func command(for event: AgentStatusHookEvent, agentName: String = "claude") -> String {
        let paneVariable = "$\(AppConstants.AgentStatus.paneIdentifierEnvironmentName)"
        let portVariable = "$\(AppConstants.AgentStatus.hookPortEnvironmentName)"
        let tokenVariable = "$\(AppConstants.AgentStatus.hookTokenEnvironmentName)"
        let url = "http://\(AppConstants.AgentStatus.hookLoopbackHost):\(portVariable)"
            + AppConstants.AgentStatus.hookRequestPath
        let body = #"{\"paneId\":\""# + paneVariable + #"\",\"state\":\""# + event.reportedState.rawValue
            + #"\",\"agent\":\""# + agentName + #"\"}"#
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
    static func installing(into settings: [String: Any]) -> [String: Any] {
        var next = removingKurottyEntries(from: settings)
        var hooks = next[AppConstants.AgentStatus.claudeHooksKey] as? [String: Any] ?? [:]
        for event in AgentStatusHookEvent.allCases {
            var matchers = hooks[event.rawValue] as? [[String: Any]] ?? []
            matchers.append([
                AppConstants.AgentStatus.claudeHookListKey: [
                    [
                        AppConstants.AgentStatus.claudeHookTypeKey: AppConstants.AgentStatus.claudeHookCommandType,
                        AppConstants.AgentStatus.claudeHookCommandKey: command(for: event),
                    ],
                ],
            ])
            hooks[event.rawValue] = matchers
        }
        next[AppConstants.AgentStatus.claudeHooksKey] = hooks
        return next
    }

    /// Removes only entries carrying Kurotty's marker. Empty containers left
    /// behind by the removal are pruned so the file does not accumulate husks.
    static func removingKurottyEntries(from settings: [String: Any]) -> [String: Any] {
        var next = settings
        guard var hooks = next[AppConstants.AgentStatus.claudeHooksKey] as? [String: Any] else {
            return next
        }
        for (eventName, value) in hooks {
            guard let matchers = value as? [[String: Any]] else {
                continue
            }
            let cleanedMatchers = matchers.compactMap { matcher -> [String: Any]? in
                guard let entries = matcher[AppConstants.AgentStatus.claudeHookListKey] as? [[String: Any]] else {
                    return matcher
                }
                let keptEntries = entries.filter { entry in
                    guard let command = entry[AppConstants.AgentStatus.claudeHookCommandKey] as? String else {
                        return true
                    }
                    return !isManagedCommand(command)
                }
                guard !keptEntries.isEmpty else {
                    return nil
                }
                var cleaned = matcher
                cleaned[AppConstants.AgentStatus.claudeHookListKey] = keptEntries
                return cleaned
            }
            if cleanedMatchers.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = cleanedMatchers
            }
        }
        if hooks.isEmpty {
            next.removeValue(forKey: AppConstants.AgentStatus.claudeHooksKey)
        } else {
            next[AppConstants.AgentStatus.claudeHooksKey] = hooks
        }
        return next
    }

    static func containsKurottyEntries(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings[AppConstants.AgentStatus.claudeHooksKey] as? [String: Any] else {
            return false
        }
        for value in hooks.values {
            guard let matchers = value as? [[String: Any]] else {
                continue
            }
            for matcher in matchers {
                guard let entries = matcher[AppConstants.AgentStatus.claudeHookListKey] as? [[String: Any]] else {
                    continue
                }
                for entry in entries {
                    guard let command = entry[AppConstants.AgentStatus.claudeHookCommandKey] as? String else {
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

    // MARK: - File I/O

    /// Installs Kurotty's hook entries. Fails soft: a missing directory, an
    /// unreadable file, or malformed JSON returns an error the caller can log.
    @discardableResult
    static func install(at fileURL: URL? = nil) -> Result<Void, InstallError> {
        let target = fileURL ?? settingsFileURL()
        return rewrite(fileURL: target, transform: installing(into:))
    }

    /// Removes Kurotty's hook entries, leaving everything else in place.
    @discardableResult
    static func uninstall(at fileURL: URL? = nil) -> Result<Void, InstallError> {
        let target = fileURL ?? settingsFileURL()
        guard FileManager.default.fileExists(atPath: target.path) else {
            return .success(())
        }
        return rewrite(fileURL: target, transform: removingKurottyEntries(from:))
    }

    private static func rewrite(
        fileURL: URL,
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
            let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(
                fileURL.lastPathComponent + ".kurotty-backup"
            )
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

/// Resolves whether hook installation is allowed.
///
/// The setting lives at `terminal.agentStatusHooksEnabled` and defaults to
/// `false` because installation edits the user's Claude Code configuration.
/// Until the key exists in `AppSettings`, callers pass `nil` and get the
/// documented default; this resolver is the single place that decides.
enum AgentStatusHookSettings {
    static let settingsKeyPath = AppConstants.AgentStatus.settingsKeyPath
    static let defaultValue = AppConstants.AgentStatus.hooksEnabledDefault

    /// Integration point: pass `settings.terminal.agentStatusHooksEnabled` once
    /// the key is added to `TerminalSettings`.
    static func isEnabled(decodedSettingValue: Bool? = nil) -> Bool {
        decodedSettingValue ?? defaultValue
    }
}
