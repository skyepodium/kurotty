import CryptoKit
import Foundation
import KurottyCore

/// Per-project shell history derivation, ported from Orca's
/// `terminal-history.ts` / `terminal-history-paths.ts`.
///
/// Kurotty previously forced `HISTFILE` to the global `~/.zsh_history` for every
/// session, which both merged unrelated projects into one history and silently
/// overrode users who configure `HISTFILE` themselves. This type derives a
/// stable per-project history file and, critically, refuses to set anything when
/// the inherited environment already defines `HISTFILE`.
///
/// Everything here is pure except the injectable `gitRootLookup`, so path
/// derivation is testable against temporary directories.
enum TerminalShellHistoryEnvironment {
    // MARK: - Constants

    /// Default for `shell.perProjectHistoryEnabled` (next-session). The live
    /// value comes from the settings file through `resolvedHistoryFilePath`.
    static var perProjectShellHistoryEnabled: Bool {
        SettingsDefaults.perProjectHistoryEnabled
    }

    static let environmentKey = AppConstants.ShellHistory.environmentKey
    static let applicationSupportDirectoryName = AppConstants.ShellHistory.applicationSupportDirectoryName
    static let historyDirectoryName = AppConstants.ShellHistory.historyDirectoryName
    static let projectHashLengthCharacters = AppConstants.ShellHistory.projectHashLengthCharacters
    static let gitDirectoryName = AppConstants.ShellHistory.gitDirectoryName
    /// Bounds the upward `.git` walk so a pathological path cannot loop.
    static let maximumGitRootWalkDepth = AppConstants.ShellHistory.maximumGitRootWalkDepth
    /// Preserved fallback when no project identity is available.
    static let globalFallbackHistoryFileName = AppConstants.ShellHistory.globalFallbackHistoryFileName
    /// Shell history is sensitive; keep the per-project tree owner-only.
    static let directoryPermissions: mode_t = AppConstants.ShellHistory.directoryPermissions

    // MARK: - Shell kind

    enum ShellKind: String, Equatable {
        case zsh
        case bash
        case fish
        case unknown
    }

    /// Resolves the shell from the binary's basename using prefix matching, so
    /// versioned names (`bash-5.2`) and nix-store paths resolve correctly.
    static func shellKind(forBinaryPath path: String) -> ShellKind {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("zsh") { return .zsh }
        if name.hasPrefix("bash") { return .bash }
        if name.hasPrefix("fish") { return .fish }
        return .unknown
    }

    /// History filename inside the per-project directory, or `nil` for shells
    /// whose history is not driven by `HISTFILE`.
    static func historyFileName(for kind: ShellKind) -> String? {
        switch kind {
        case .zsh: return AppConstants.ShellHistory.zshHistoryFileName
        case .bash: return AppConstants.ShellHistory.bashHistoryFileName
        // fish uses its own history session mechanism, not HISTFILE.
        case .fish, .unknown: return nil
        }
    }

    // MARK: - Project identity

    /// Stable identity for the session's initial working directory: the git root
    /// when one is found, otherwise the directory itself.
    static func projectIdentity(
        forWorkingDirectory workingDirectory: String?,
        gitRootLookup: (String) -> String? = defaultGitRootLookup
    ) -> String? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        let standardized = (workingDirectory as NSString).standardizingPath
        guard !standardized.isEmpty else { return nil }
        return gitRootLookup(standardized) ?? standardized
    }

    /// Walks upward looking for a `.git` entry. Bounded and stat-only, so it is
    /// cheap enough for the shell launch boundary.
    static func defaultGitRootLookup(_ directory: String) -> String? {
        var current = directory
        var depth = 0
        while depth < maximumGitRootWalkDepth {
            let marker = (current as NSString).appendingPathComponent(gitDirectoryName)
            if FileManager.default.fileExists(atPath: marker) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { return nil }
            current = parent
            depth += 1
        }
        return nil
    }

    /// First `projectHashLengthCharacters` hex characters of SHA-256, matching
    /// Orca's `hashWorktreeId`.
    static func projectHash(_ identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(projectHashLengthCharacters))
    }

    // MARK: - Path derivation

    static func historyRoot(applicationSupportDirectory: String) -> String {
        (applicationSupportDirectory as NSString)
            .appendingPathComponent(applicationSupportDirectoryName)
            .appending("/" + historyDirectoryName)
    }

    static func historyFilePath(
        historyRoot: String,
        projectHash: String,
        shellKind: ShellKind
    ) -> String? {
        guard let fileName = historyFileName(for: shellKind) else { return nil }
        return (historyRoot as NSString)
            .appendingPathComponent(projectHash)
            .appending("/" + fileName)
    }

    // MARK: - Resolution

    /// The `HISTFILE` value a new session should export.
    ///
    /// Returns `nil` when Kurotty must not touch `HISTFILE` at all: the user
    /// already defines it, the feature is disabled, the shell does not use
    /// `HISTFILE`, or there is no usable working directory. `nil` from a
    /// check-before-set hit is the important case — the caller must not fall
    /// back to the global history file then.
    static func resolvedHistoryFilePath(
        workingDirectory: String?,
        shellPath: String,
        inheritedHistoryFile: String?,
        applicationSupportDirectory: String,
        isEnabled: Bool = perProjectShellHistoryEnabled,
        gitRootLookup: (String) -> String? = defaultGitRootLookup
    ) -> String? {
        // Check-before-set: an explicitly configured HISTFILE always wins.
        if let inheritedHistoryFile, !inheritedHistoryFile.isEmpty { return nil }
        guard isEnabled else { return nil }
        let kind = shellKind(forBinaryPath: shellPath)
        guard historyFileName(for: kind) != nil else { return nil }
        guard let identity = projectIdentity(
            forWorkingDirectory: workingDirectory,
            gitRootLookup: gitRootLookup
        ) else { return nil }
        return historyFilePath(
            historyRoot: historyRoot(applicationSupportDirectory: applicationSupportDirectory),
            projectHash: projectHash(identity),
            shellKind: kind
        )
    }

    /// Whether the caller may still export the legacy global history file. This
    /// is the "cwd unknown" fallback and stays check-before-set.
    static func shouldUseGlobalFallback(inheritedHistoryFile: String?) -> Bool {
        guard let inheritedHistoryFile else { return true }
        return inheritedHistoryFile.isEmpty
    }

    /// User Application Support directory for the current user.
    static func defaultApplicationSupportDirectory() -> String {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        if let url = urls.first { return url.path }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support").path
    }
}
