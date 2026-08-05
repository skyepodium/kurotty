import Foundation

/// Pure presentation layer for the status bar's git-worktree segment and its
/// popover: what the segment says, what each popover row says, and what shell
/// command a row selection inserts.
///
/// Everything here is deterministic and free of AppKit and of `Process`, so the
/// copy rules can be unit-tested without a repository on disk.

// MARK: - Segment summary

/// Everything the worktree segment renders, resolved from one snapshot.
struct TerminalStatusBarWorktreeSummary: Equatable, Sendable {
    /// Branch name, short commit for a detached checkout, or the directory name
    /// when git reported neither.
    let name: String
    let isDirty: Bool
    let isMain: Bool
    /// Number of worktrees in the repository; the segment shows a count badge
    /// once there is more than one, exactly like the agent segment.
    let worktreeCount: Int
    /// Full text for the tooltip, used verbatim when truncation hides parts.
    let tooltip: String
    /// False when the pane is not inside a worktree at all. The segment is
    /// hidden rather than rendered empty.
    let isPresent: Bool

    static let absent = TerminalStatusBarWorktreeSummary(
        name: "",
        isDirty: false,
        isMain: false,
        worktreeCount: 0,
        tooltip: "",
        isPresent: false
    )

    /// Name plus the universal uncommitted-changes marker.
    var displayText: String {
        guard isDirty else {
            return name
        }
        return name + AppConstants.GitWorktree.dirtyMarker
    }
}

/// Pure composition of the segment from a collected snapshot.
enum TerminalStatusBarWorktreeComposer {
    private enum Format {
        static let tooltipLineSeparator = "\n"
    }

    static func summary(
        snapshot: TerminalGitWorktreeSnapshot?,
        language: AppLanguage = AppLocalization.language
    ) -> TerminalStatusBarWorktreeSummary {
        guard let snapshot, let current = snapshot.currentWorktree else {
            return .absent
        }
        let name = TerminalStatusBarWorktreeText.name(for: current, language: language)
        let isDirty = snapshot.dirtyPaths.contains(current.path)
        return TerminalStatusBarWorktreeSummary(
            name: name,
            isDirty: isDirty,
            isMain: current.isMain,
            worktreeCount: snapshot.worktrees.filter { !$0.isBare }.count,
            tooltip: tooltip(worktree: current, name: name, isDirty: isDirty, language: language),
            isPresent: true
        )
    }

    private static func tooltip(
        worktree: GitWorktree,
        name: String,
        isDirty: Bool,
        language: AppLanguage
    ) -> String {
        var lines = [
            "\(name) \(AppConstants.StatusBar.detailSeparator) \(worktree.path)",
            AppLocalization.string(
                worktree.isMain ? .statusBarWorktreeMainDescription : .statusBarWorktreeLinkedDescription,
                language: language
            ),
        ]
        if isDirty {
            lines.append(AppLocalization.string(.statusBarWorktreeDirtyDescription, language: language))
        }
        if worktree.isLocked {
            lines.append(AppLocalization.string(.statusBarWorktreeLocked, language: language))
        }
        return lines.joined(separator: Format.tooltipLineSeparator)
    }
}

// MARK: - Row text

/// Copy rules shared by the segment and the popover rows.
enum TerminalStatusBarWorktreeText {
    /// A worktree is named by its branch. A detached checkout has none, so it
    /// is named by its short commit plus the `detached` tag; if git reported
    /// neither, the directory name is the last honest fallback.
    static func name(
        for worktree: GitWorktree,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        if let branchName = worktree.branchName, !branchName.isEmpty {
            return branchName
        }
        guard let shortHeadSHA = worktree.shortHeadSHA, !shortHeadSHA.isEmpty else {
            return worktree.directoryName
        }
        let detached = AppLocalization.string(.statusBarWorktreeDetached, language: language)
        return "\(shortHeadSHA) \(AppConstants.StatusBar.labelSeparator) \(detached)"
    }

    /// Secondary text for one popover row: the `main` tag, the lock tag, and
    /// the number of indexed agent sessions working inside that worktree,
    /// joined by the same separator the rest of the bar uses.
    static func rowDetail(
        for row: GitWorktreeRow,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        var parts: [String] = []
        if row.worktree.isMain {
            parts.append(AppLocalization.string(.statusBarWorktreeMainTag, language: language))
        }
        if row.worktree.isLocked {
            parts.append(AppLocalization.string(.statusBarWorktreeLocked, language: language))
        }
        if row.agentSessionCount > 0 {
            let countKey: L10nKey = row.agentSessionCount == 1
                ? .statusBarWorktreeSessionCountOne
                : .statusBarWorktreeSessionCount
            parts.append(String(
                format: AppLocalization.string(countKey, language: language),
                locale: Locale(identifier: language.rawValue),
                row.agentSessionCount
            ))
        }
        return parts.joined(separator: " \(AppConstants.StatusBar.labelSeparator) ")
    }

    /// Branch text for one popover row, carrying the dirty marker.
    static func rowName(
        for row: GitWorktreeRow,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        let name = name(for: row.worktree, language: language)
        guard row.isDirty else {
            return name
        }
        return name + AppConstants.GitWorktree.dirtyMarker
    }
}

// MARK: - Change-directory command

/// Pure construction of the shell command a worktree row inserts.
///
/// The command is only ever inserted at the prompt, exactly like
/// `AgentSessionResumeCommand`: there is no execute path, so the user always
/// presses Return themselves.
enum GitWorktreeChangeDirectoryCommand {
    private enum Syntax {
        static let changeDirectory = "cd"
    }

    static func command(for worktree: GitWorktree) -> String {
        "\(Syntax.changeDirectory) \(TerminalShellPathQuoting.quoted(worktree.path))"
    }
}
