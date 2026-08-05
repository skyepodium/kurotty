import Foundation

enum AppLanguage: String, CaseIterable, Equatable {
    case english = "en"
    case korean = "ko"
    case japanese = "ja"

    init?(languageIdentifier: String) {
        guard let code = Locale(identifier: languageIdentifier).language.languageCode?.identifier
            ?? languageIdentifier.split(separator: "-").first.map(String.init)
        else {
            return nil
        }
        self.init(rawValue: code)
    }
}

enum AppLanguagePreference: String, CaseIterable, Equatable {
    case system
    case english = "en"
    case korean = "ko"
    case japanese = "ja"

    var explicitLanguage: AppLanguage? {
        AppLanguage(rawValue: rawValue)
    }
}

enum AppLanguageResolver {
    static func resolve(
        preference: AppLanguagePreference,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        if let explicitLanguage = preference.explicitLanguage {
            return explicitLanguage
        }
        guard let systemLanguage = preferredLanguages.first else {
            return .english
        }
        return AppLanguage(languageIdentifier: systemLanguage) ?? .english
    }
}

enum L10nKey: String, CaseIterable {
    case about, checkForUpdates, settings, quit
    case shell, newWindow, newTab, closePaneOrTab, splitVertically, splitHorizontally, previousTab, nextTab
    case commandPalette, findTerminalOutput, findTerminalOutputPlaceholder
    case previousSearchMatch, nextSearchMatch, closeSearch
    case edit, cut, copy, paste
    case language, systemDefault, english, korean, japanese
    case searchCommands, command, requiresConfirmation
    case closePane, focusPaneLeft, focusPaneRight, focusPaneDown, focusPaneUp
    case splitRight, splitLeft, splitDown, splitUp
    case replayCommandQuestion, openLinkQuestion, cancel, open, openInBrowser, replay
    case pasteLinesQuestion, pasteLinesExplanation, pasteConfirm, pasteTooLargeTitle, pasteTooLargeExplanation
    case updateUnavailableTitle, updateUnavailableMessage, ok
    case moveToApplicationsTitle, moveToApplicationsMessage, moveToApplications, moveToApplicationsLater
    case moveToApplicationsFailedTitle, moveToApplicationsFailedMessage, translocatedMessage
    case help, copyDiagnosticsReport, diagnosticsReportCopiedTitle, diagnosticsReportCopiedMessage
    case settingsWindow, settingsValid, errors, warnings
    case invalidSettingsJSON, settingsLoaded, settingsLoadFailed, settingsNotApplied, settingsApplying, settingsApplied, settingsApplyFailed
    case tmuxSwapPanePrevious, tmuxSwapPaneNext, tmuxRotatePanesPrevious, tmuxRotatePanesNext
    case tmuxTogglePaneZoom, tmuxNextLayout, tmuxPreviousLayout, tmuxEvenHorizontalLayout
    case tmuxEvenVerticalLayout, tmuxDetachClient
    case foldCommandOutput, copyCommandReference, replayCommand
    case foldCommandOutputSubtitle, copyCommandReferenceSubtitle, replayCommandSubtitle
    case view, commandHistory, commandHistoryFilterPlaceholder, commandHistoryEmpty, commandHistoryDisabledExplanation, commandHistorySectionTitle
    case insertIntoTerminal, runAgain, copyCommand, copyChangeDirectoryCommand, revealDirectoryInFinder
    case fileExplorer, fileExplorerSearchPlaceholder, fileExplorerSegmentName, fileExplorerSegmentContent
    case refresh, revealInFinder, copyPath, insertPathIntoTerminal
    case editorBinaryFile, editorFileTooLarge, editorLoadFailed
    case unsavedChangesQuestion, save, discardChanges
    case agentSessions, agentSessionsSectionTitle, agentSessionsFilterPlaceholder
    case agentSessionsEmpty, agentSessionsDisabledExplanation
    case insertResumeCommand, copyResumeCommand, copySessionIdentifier, copyTranscriptPath
    case revealTranscriptInFinder, openDirectoryInExplorer
    case fileExplorerRemoteTitle, fileExplorerRemoteExplanation
    case agentStatusWorking, agentStatusWaitingForInput, agentStatusBlocked, agentStatusDone
    case quickCommands, quickCommandsMenuTitle, quickCommandsEditorTitle, quickCommandsEmptyState
    case quickCommandsPaletteCategory, quickCommandScopeGlobal, quickCommandScopeDirectory
    case quickCommandActionTerminalCommand, quickCommandActionAgentPrompt
    case quickCommandInsertsOnly, quickCommandRunsImmediately
    case quickCommandColumnName, quickCommandColumnScope, quickCommandColumnAction
    case quickCommandFieldName, quickCommandFieldCommandText, quickCommandFieldScopeDirectory
    case quickCommandFieldAppendEnter, quickCommandFieldShortcut
    case quickCommandAdd, quickCommandRemove, quickCommandDone
    case quickCommandChooseDirectory, quickCommandClearDirectory, quickCommandUntitled
    case quickCommandSeedGitStatus, quickCommandSeedGitDiffStat
    case quickCommandSeedGitLogGraph, quickCommandSeedClaudeResume
    case openTranscript, transcriptEmpty, transcriptReadOnly, transcriptOlderRecordsHidden
    case transcriptRoleUser, transcriptRoleAgent, transcriptRoleTool, transcriptRoleSystem
    case collapseAllToolRuns
    // Bottom status bar. `cancel` is deliberately absent: the bar reuses the
    // existing `.cancel` key rather than shipping a second "Cancel".
    case statusBarAgentIdle, statusBarAgentWorking, statusBarAgentNeedsInput, statusBarAgentBlocked
    case statusBarNoAgent, statusBarConnectAnAgent, statusBarConnectAnAgentTooltip
    case statusBarEnableStatusHooksTitle, statusBarEnableStatusHooksMessage, statusBarOpenPreferences
    case statusBarHistoryTitle, statusBarResumeLastSession
    case statusBarProcessUsageTitle, statusBarMemoryDescription
    case statusBarQuitProcess, statusBarQuitProcessTitle, statusBarQuitProcessMessage
    case statusBarQuitProcessConfirm, statusBarNoProcesses
    // Agent token usage strip.
    case agentUsageToday, agentUsageInput, agentUsageOutput, agentUsageCache, agentUsageAccessibility
    // Agent context-window forecast.
    case agentContextLabel, agentContextOfLimit, agentContextTurnsLeft
    case agentContextOverLimit, agentContextLimitUnknown, agentContextAccessibility
}

enum AppLocalization {
    static let preferenceKey = "appLanguagePreference"

    static var preference: AppLanguagePreference {
        get {
            guard let value = UserDefaults.standard.string(forKey: preferenceKey),
                  let preference = AppLanguagePreference(rawValue: value)
            else {
                return .system
            }
            return preference
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: preferenceKey)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
            }
        }
    }

    static var language: AppLanguage {
        AppLanguageResolver.resolve(preference: preference)
    }

    static func string(_ key: L10nKey, language: AppLanguage = language) -> String {
        translations[language]?[key] ?? translations[.english]?[key] ?? key.rawValue
    }

    static func format(_ key: L10nKey, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: language.rawValue), arguments: arguments)
    }

    static func hasTranslation(for key: L10nKey, language: AppLanguage) -> Bool {
        translations[language]?[key] != nil
    }

    private static let translations: [AppLanguage: [L10nKey: String]] = [
        .english: [
            .about: "About %@", .checkForUpdates: "Check for Updates...", .settings: "Settings...", .quit: "Quit %@",
            .shell: "Shell", .newWindow: "New Window", .newTab: "New Tab", .closePaneOrTab: "Close Pane or Tab",
            .splitVertically: "Split Vertically", .splitHorizontally: "Split Horizontally", .previousTab: "Previous Tab", .nextTab: "Next Tab",
            .commandPalette: "Command Palette", .findTerminalOutput: "Find Terminal Output", .findTerminalOutputPlaceholder: "Find",
            .previousSearchMatch: "Previous Match", .nextSearchMatch: "Next Match", .closeSearch: "Close Search",
            .edit: "Edit", .cut: "Cut", .copy: "Copy", .paste: "Paste",
            .language: "Language", .systemDefault: "Follow System Language", .english: "English", .korean: "Korean", .japanese: "Japanese",
            .searchCommands: "Search commands", .command: "Command", .requiresConfirmation: "Requires confirmation",
            .closePane: "Close Pane", .focusPaneLeft: "Focus Pane Left", .focusPaneRight: "Focus Pane Right", .focusPaneDown: "Focus Pane Down", .focusPaneUp: "Focus Pane Up",
            .splitRight: "Split Right", .splitLeft: "Split Left", .splitDown: "Split Down", .splitUp: "Split Up",
            .replayCommandQuestion: "Replay Command?", .openLinkQuestion: "Open Link?", .cancel: "Cancel", .open: "Open", .openInBrowser: "Open in Browser", .replay: "Replay",
            .pasteLinesQuestion: "Paste %d lines?", .pasteLinesExplanation: "The shell can run every line this paste contains.", .pasteConfirm: "Paste",
            .pasteTooLargeTitle: "Paste Too Large", .pasteTooLargeExplanation: "This clipboard content is %d bytes, above the %d byte paste limit.",
            .updateUnavailableTitle: "Automatic Updates Unavailable", .updateUnavailableMessage: "This build is not signed for updates, so automatic download and installation cannot start. Official release builds download and install updates automatically.", .ok: "OK",
            .moveToApplicationsTitle: "Move to Applications?", .moveToApplicationsMessage: "%@ is running from a read-only or temporary location, so it cannot update itself. Moving it to the Applications folder and relaunching fixes that.", .moveToApplications: "Move and Relaunch", .moveToApplicationsLater: "Not Now",
            .moveToApplicationsFailedTitle: "Move Failed", .moveToApplicationsFailedMessage: "The Applications folder could not be written to: %@", .translocatedMessage: "macOS is running %@ from a randomized read-only copy, so it cannot update itself and cannot move itself either. Move the app to the Applications folder in Finder, then open it from there.",
            .help: "Help", .copyDiagnosticsReport: "Copy Diagnostics Report",
            .diagnosticsReportCopiedTitle: "Diagnostics Report Copied", .diagnosticsReportCopiedMessage: "The report is on the clipboard. It contains version, renderer, and event counts only — no terminal output, commands, or full paths.",
            .settingsWindow: "%@ Settings", .settingsValid: "Settings valid.", .errors: "Errors", .warnings: "Warnings",
            .invalidSettingsJSON: "Settings JSON is invalid: %@", .settingsLoaded: "Loaded %@. Edits apply automatically. %@", .settingsLoadFailed: "Load failed: %@", .settingsNotApplied: "Not applied. %@", .settingsApplying: "Applying settings. %@", .settingsApplied: "Applied %@. %@", .settingsApplyFailed: "Apply failed: %@",
            .tmuxSwapPanePrevious: "Tmux: Swap Pane Previous", .tmuxSwapPaneNext: "Tmux: Swap Pane Next", .tmuxRotatePanesPrevious: "Tmux: Rotate Panes Previous", .tmuxRotatePanesNext: "Tmux: Rotate Panes Next",
            .tmuxTogglePaneZoom: "Tmux: Toggle Pane Zoom", .tmuxNextLayout: "Tmux: Next Layout", .tmuxPreviousLayout: "Tmux: Previous Layout", .tmuxEvenHorizontalLayout: "Tmux: Even Horizontal Layout",
            .tmuxEvenVerticalLayout: "Tmux: Even Vertical Layout", .tmuxDetachClient: "Tmux: Detach Client",
            .foldCommandOutput: "Fold Command Output", .copyCommandReference: "Copy Command Reference", .replayCommand: "Replay Command",
            .foldCommandOutputSubtitle: "Collapse a completed command's output while keeping the command reference.", .copyCommandReferenceSubtitle: "Copy a stable command-span reference without including raw output.", .replayCommandSubtitle: "Run the captured command again after explicit confirmation.",
            .view: "View", .commandHistory: "Command History", .commandHistoryFilterPlaceholder: "Search", .commandHistoryEmpty: "Commands you run appear here.", .commandHistoryDisabledExplanation: "Command history is turned off in Settings.", .commandHistorySectionTitle: "History",
            .insertIntoTerminal: "Insert into Terminal", .runAgain: "Run Again...", .copyCommand: "Copy Command", .copyChangeDirectoryCommand: "Copy 'cd' Command", .revealDirectoryInFinder: "Reveal Directory in Finder",
            .fileExplorer: "File Explorer", .fileExplorerSearchPlaceholder: "Find files", .fileExplorerSegmentName: "Name", .fileExplorerSegmentContent: "Content",
            .refresh: "Refresh", .revealInFinder: "Reveal in Finder", .copyPath: "Copy Path", .insertPathIntoTerminal: "Insert Path into Terminal",
            .editorBinaryFile: "Binary file", .editorFileTooLarge: "File too large", .editorLoadFailed: "Could not open file",
            .unsavedChangesQuestion: "Save changes to \"%@\"?", .save: "Save", .discardChanges: "Don't Save",
            .agentSessions: "Agent Sessions", .agentSessionsSectionTitle: "Agent Sessions", .agentSessionsFilterPlaceholder: "Search sessions",
            .agentSessionsEmpty: "AI agent sessions stored on this Mac appear here.", .agentSessionsDisabledExplanation: "Agent session indexing is turned off in Settings.",
            .insertResumeCommand: "Insert Resume Command", .copyResumeCommand: "Copy Resume Command", .copySessionIdentifier: "Copy Session ID", .copyTranscriptPath: "Copy Transcript Path",
            .revealTranscriptInFinder: "Reveal Transcript in Finder", .openDirectoryInExplorer: "Open Directory in Explorer Panel",
            .fileExplorerRemoteTitle: "Remote directory", .fileExplorerRemoteExplanation: "%@ is on another machine. The explorer shows local files only.",
            .agentStatusWorking: "Working", .agentStatusWaitingForInput: "Waiting for input", .agentStatusBlocked: "Blocked", .agentStatusDone: "Done",
            .quickCommands: "Quick Commands", .quickCommandsMenuTitle: "Quick Commands", .quickCommandsEditorTitle: "Quick Commands", .quickCommandsEmptyState: "No quick commands yet.",
            .quickCommandsPaletteCategory: "Quick Commands", .quickCommandScopeGlobal: "All directories", .quickCommandScopeDirectory: "In %@",
            .quickCommandActionTerminalCommand: "Terminal command", .quickCommandActionAgentPrompt: "Agent prompt",
            .quickCommandInsertsOnly: "Inserts without running", .quickCommandRunsImmediately: "Runs immediately",
            .quickCommandColumnName: "Name", .quickCommandColumnScope: "Scope", .quickCommandColumnAction: "Action",
            .quickCommandFieldName: "Name", .quickCommandFieldCommandText: "Command text", .quickCommandFieldScopeDirectory: "Only in directory",
            .quickCommandFieldAppendEnter: "Press Return after inserting (runs the command)", .quickCommandFieldShortcut: "Shortcut",
            .quickCommandAdd: "Add", .quickCommandRemove: "Remove", .quickCommandDone: "Done",
            .quickCommandChooseDirectory: "Choose…", .quickCommandClearDirectory: "All directories", .quickCommandUntitled: "Untitled Command",
            .quickCommandSeedGitStatus: "Git Status", .quickCommandSeedGitDiffStat: "Git Diff Stat",
            .quickCommandSeedGitLogGraph: "Git Log Graph", .quickCommandSeedClaudeResume: "Resume Claude Session",
            .openTranscript: "Open Transcript", .transcriptEmpty: "This transcript has no readable records yet.",
            .transcriptReadOnly: "Read-only", .transcriptOlderRecordsHidden: "Older records are not shown.",
            .transcriptRoleUser: "You", .transcriptRoleAgent: "Agent", .transcriptRoleTool: "Tool", .transcriptRoleSystem: "System",
            .collapseAllToolRuns: "Collapse All Tool Runs",
            .statusBarAgentIdle: "Idle", .statusBarAgentWorking: "Working", .statusBarAgentNeedsInput: "Needs input", .statusBarAgentBlocked: "Blocked",
            .statusBarNoAgent: "No agent", .statusBarConnectAnAgent: "Connect an agent",
            .statusBarConnectAnAgentTooltip: "Agent status hooks are off. Open Preferences to enable them.",
            .statusBarEnableStatusHooksTitle: "Enable agent status hooks?",
            .statusBarEnableStatusHooksMessage: "Agent status reporting is opt-in. Enable it in Preferences to see live agent state here.",
            .statusBarOpenPreferences: "Open Preferences",
            .statusBarHistoryTitle: "Recent agent status", .statusBarResumeLastSession: "Resume last session",
            .statusBarProcessUsageTitle: "Process usage",
            .statusBarMemoryDescription: "Summed resident set size (RSS). Shared or aliased pages can appear in more than one process.",
            .statusBarQuitProcess: "Quit process", .statusBarQuitProcessTitle: "Quit this process?",
            .statusBarQuitProcessMessage: "The pane's shell process tree is asked to terminate, then force-quit if it does not exit. Unsaved work in that pane is lost.",
            .statusBarQuitProcessConfirm: "Quit", .statusBarNoProcesses: "No pane processes are being sampled.",
            .agentUsageToday: "TODAY", .agentUsageInput: "in", .agentUsageOutput: "out", .agentUsageCache: "cache", .agentUsageAccessibility: "%1$@ tokens today across %2$d sessions",
            .agentContextLabel: "Context",
            .agentContextOfLimit: "%1$d%% of %2$@",
            .agentContextTurnsLeft: "~%d turns left",
            .agentContextOverLimit: "over limit",
            .agentContextLimitUnknown: "%@ used, limit unknown",
            .agentContextAccessibility: "Context %1$d%% used",
        ],
        .korean: [
            .about: "%@ 정보", .checkForUpdates: "업데이트 확인...", .settings: "설정...", .quit: "%@ 종료",
            .shell: "셸", .newWindow: "새 윈도우", .newTab: "새 탭", .closePaneOrTab: "패널 또는 탭 닫기",
            .splitVertically: "좌우로 분할", .splitHorizontally: "상하로 분할", .previousTab: "이전 탭", .nextTab: "다음 탭",
            .commandPalette: "명령 팔레트", .findTerminalOutput: "터미널 출력 찾기", .findTerminalOutputPlaceholder: "찾기",
            .previousSearchMatch: "이전 일치 항목", .nextSearchMatch: "다음 일치 항목", .closeSearch: "검색 닫기",
            .edit: "편집", .cut: "오려두기", .copy: "복사", .paste: "붙여넣기",
            .language: "언어", .systemDefault: "시스템 언어 따라가기", .english: "영어", .korean: "한국어", .japanese: "일본어",
            .searchCommands: "명령 검색", .command: "명령", .requiresConfirmation: "확인 필요",
            .closePane: "패널 닫기", .focusPaneLeft: "왼쪽 패널로 이동", .focusPaneRight: "오른쪽 패널로 이동", .focusPaneDown: "아래 패널로 이동", .focusPaneUp: "위 패널로 이동",
            .splitRight: "오른쪽으로 분할", .splitLeft: "왼쪽으로 분할", .splitDown: "아래로 분할", .splitUp: "위로 분할",
            .replayCommandQuestion: "명령을 다시 실행할까요?", .openLinkQuestion: "링크를 열까요?", .cancel: "취소", .open: "열기", .openInBrowser: "브라우저에서 열기", .replay: "다시 실행",
            .pasteLinesQuestion: "%d줄을 붙여넣을까요?", .pasteLinesExplanation: "이 붙여넣기에 포함된 모든 줄이 셸에서 실행될 수 있습니다.", .pasteConfirm: "붙여넣기",
            .pasteTooLargeTitle: "붙여넣기 내용이 너무 큽니다", .pasteTooLargeExplanation: "클립보드 내용이 %d바이트로, 붙여넣기 한도 %d바이트를 넘습니다.",
            .updateUnavailableTitle: "자동 업데이트를 사용할 수 없습니다", .updateUnavailableMessage: "이 빌드에는 업데이트 서명이 없어 자동 다운로드와 설치를 시작할 수 없습니다. 정식 배포 빌드에서는 업데이트를 자동으로 내려받고 설치합니다.", .ok: "확인",
            .moveToApplicationsTitle: "응용 프로그램 폴더로 옮길까요?", .moveToApplicationsMessage: "%@이(가) 읽기 전용이거나 임시 위치에서 실행 중이라 스스로 업데이트할 수 없습니다. 응용 프로그램 폴더로 옮기고 다시 실행하면 해결됩니다.", .moveToApplications: "옮기고 다시 실행", .moveToApplicationsLater: "나중에",
            .moveToApplicationsFailedTitle: "옮기지 못했습니다", .moveToApplicationsFailedMessage: "응용 프로그램 폴더에 쓸 수 없습니다: %@", .translocatedMessage: "macOS가 %@을(를) 무작위 읽기 전용 사본으로 실행하고 있어 스스로 업데이트할 수도, 옮길 수도 없습니다. Finder에서 앱을 응용 프로그램 폴더로 옮긴 뒤 거기서 실행해 주세요.",
            .help: "도움말", .copyDiagnosticsReport: "진단 리포트 복사",
            .diagnosticsReportCopiedTitle: "진단 리포트를 복사했습니다", .diagnosticsReportCopiedMessage: "리포트가 클립보드에 있습니다. 버전, 렌더러, 이벤트 개수만 포함하며 터미널 출력, 명령어, 전체 경로는 들어 있지 않습니다.",
            .settingsWindow: "%@ 설정", .settingsValid: "설정이 유효합니다.", .errors: "오류", .warnings: "경고",
            .invalidSettingsJSON: "설정 JSON이 올바르지 않습니다: %@", .settingsLoaded: "%@을(를) 불러왔습니다. 변경 사항은 자동으로 적용됩니다. %@", .settingsLoadFailed: "불러오기 실패: %@", .settingsNotApplied: "적용되지 않았습니다. %@", .settingsApplying: "설정을 적용하는 중입니다. %@", .settingsApplied: "%@에 적용했습니다. %@", .settingsApplyFailed: "적용 실패: %@",
            .tmuxSwapPanePrevious: "Tmux: 이전 패널과 교체", .tmuxSwapPaneNext: "Tmux: 다음 패널과 교체", .tmuxRotatePanesPrevious: "Tmux: 패널을 이전 방향으로 회전", .tmuxRotatePanesNext: "Tmux: 패널을 다음 방향으로 회전",
            .tmuxTogglePaneZoom: "Tmux: 패널 확대 전환", .tmuxNextLayout: "Tmux: 다음 레이아웃", .tmuxPreviousLayout: "Tmux: 이전 레이아웃", .tmuxEvenHorizontalLayout: "Tmux: 좌우 균등 레이아웃",
            .tmuxEvenVerticalLayout: "Tmux: 상하 균등 레이아웃", .tmuxDetachClient: "Tmux: 클라이언트 분리",
            .foldCommandOutput: "명령 출력 접기", .copyCommandReference: "명령 참조 복사", .replayCommand: "명령 다시 실행",
            .foldCommandOutputSubtitle: "명령 참조는 유지하고 완료된 명령 출력을 접습니다.", .copyCommandReferenceSubtitle: "원본 출력을 제외하고 안정적인 명령 범위 참조를 복사합니다.", .replayCommandSubtitle: "확인 후 캡처한 명령을 다시 실행합니다.",
            .view: "보기", .commandHistory: "명령 기록", .commandHistoryFilterPlaceholder: "검색", .commandHistoryEmpty: "실행한 명령이 여기에 표시됩니다.", .commandHistoryDisabledExplanation: "설정에서 명령 기록이 꺼져 있습니다.", .commandHistorySectionTitle: "기록",
            .insertIntoTerminal: "터미널에 입력", .runAgain: "다시 실행...", .copyCommand: "명령 복사", .copyChangeDirectoryCommand: "'cd' 명령 복사", .revealDirectoryInFinder: "Finder에서 폴더 보기",
            .fileExplorer: "파일 탐색기", .fileExplorerSearchPlaceholder: "파일 찾기", .fileExplorerSegmentName: "이름", .fileExplorerSegmentContent: "내용",
            .refresh: "새로 고침", .revealInFinder: "Finder에서 보기", .copyPath: "경로 복사", .insertPathIntoTerminal: "터미널에 경로 입력",
            .editorBinaryFile: "바이너리 파일", .editorFileTooLarge: "파일이 너무 큽니다", .editorLoadFailed: "파일을 열 수 없습니다",
            .unsavedChangesQuestion: "\"%@\"의 변경 사항을 저장할까요?", .save: "저장", .discardChanges: "저장 안 함",
            .agentSessions: "에이전트 세션", .agentSessionsSectionTitle: "에이전트 세션", .agentSessionsFilterPlaceholder: "세션 검색",
            .agentSessionsEmpty: "이 Mac에 저장된 AI 에이전트 세션이 여기에 표시됩니다.", .agentSessionsDisabledExplanation: "설정에서 에이전트 세션 색인이 꺼져 있습니다.",
            .insertResumeCommand: "이어하기 명령 입력", .copyResumeCommand: "이어하기 명령 복사", .copySessionIdentifier: "세션 ID 복사", .copyTranscriptPath: "대화 기록 경로 복사",
            .revealTranscriptInFinder: "Finder에서 대화 기록 보기", .openDirectoryInExplorer: "탐색기 패널에서 폴더 열기",
            .fileExplorerRemoteTitle: "원격 디렉터리", .fileExplorerRemoteExplanation: "%@은(는) 다른 컴퓨터에 있습니다. 탐색기는 로컬 파일만 표시합니다.",
            .agentStatusWorking: "작업 중", .agentStatusWaitingForInput: "입력 대기 중", .agentStatusBlocked: "차단됨", .agentStatusDone: "완료",
            .quickCommands: "빠른 명령", .quickCommandsMenuTitle: "빠른 명령", .quickCommandsEditorTitle: "빠른 명령", .quickCommandsEmptyState: "저장된 빠른 명령이 없습니다.",
            .quickCommandsPaletteCategory: "빠른 명령", .quickCommandScopeGlobal: "모든 디렉터리", .quickCommandScopeDirectory: "%@ 에서만",
            .quickCommandActionTerminalCommand: "터미널 명령", .quickCommandActionAgentPrompt: "에이전트 프롬프트",
            .quickCommandInsertsOnly: "실행하지 않고 입력만", .quickCommandRunsImmediately: "바로 실행",
            .quickCommandColumnName: "이름", .quickCommandColumnScope: "범위", .quickCommandColumnAction: "동작",
            .quickCommandFieldName: "이름", .quickCommandFieldCommandText: "명령 텍스트", .quickCommandFieldScopeDirectory: "이 디렉터리에서만",
            .quickCommandFieldAppendEnter: "입력 후 Return 누르기 (명령을 실행합니다)", .quickCommandFieldShortcut: "단축키",
            .quickCommandAdd: "추가", .quickCommandRemove: "삭제", .quickCommandDone: "완료",
            .quickCommandChooseDirectory: "선택…", .quickCommandClearDirectory: "모든 디렉터리", .quickCommandUntitled: "제목 없는 명령",
            .quickCommandSeedGitStatus: "Git 상태", .quickCommandSeedGitDiffStat: "Git 변경 요약",
            .quickCommandSeedGitLogGraph: "Git 로그 그래프", .quickCommandSeedClaudeResume: "Claude 세션 이어하기",
            .openTranscript: "대화 기록 열기", .transcriptEmpty: "이 대화 기록에는 아직 읽을 수 있는 항목이 없습니다.",
            .transcriptReadOnly: "읽기 전용", .transcriptOlderRecordsHidden: "이전 항목은 표시되지 않습니다.",
            .transcriptRoleUser: "나", .transcriptRoleAgent: "에이전트", .transcriptRoleTool: "도구", .transcriptRoleSystem: "시스템",
            .collapseAllToolRuns: "모든 도구 실행 접기",
            .statusBarAgentIdle: "대기", .statusBarAgentWorking: "작업 중", .statusBarAgentNeedsInput: "입력 필요", .statusBarAgentBlocked: "차단됨",
            .statusBarNoAgent: "에이전트 없음", .statusBarConnectAnAgent: "에이전트 연결",
            .statusBarConnectAnAgentTooltip: "에이전트 상태 후크가 꺼져 있습니다. 환경설정에서 켜세요.",
            .statusBarEnableStatusHooksTitle: "에이전트 상태 후크를 켤까요?",
            .statusBarEnableStatusHooksMessage: "에이전트 상태 보고는 선택 기능입니다. 환경설정에서 켜면 여기에 상태가 표시됩니다.",
            .statusBarOpenPreferences: "환경설정 열기",
            .statusBarHistoryTitle: "최근 에이전트 상태", .statusBarResumeLastSession: "마지막 세션 이어하기",
            .statusBarProcessUsageTitle: "프로세스 사용량",
            .statusBarMemoryDescription: "실제 메모리 사용량(RSS)의 합계입니다. 공유되거나 중복 매핑된 페이지는 여러 프로세스에 함께 계산될 수 있습니다.",
            .statusBarQuitProcess: "프로세스 종료", .statusBarQuitProcessTitle: "이 프로세스를 종료할까요?",
            .statusBarQuitProcessMessage: "패널의 셸 프로세스 트리에 종료를 요청하고, 응답이 없으면 강제 종료합니다. 저장하지 않은 작업은 사라집니다.",
            .statusBarQuitProcessConfirm: "종료", .statusBarNoProcesses: "샘플링 중인 패널 프로세스가 없습니다.",
            .agentUsageToday: "오늘", .agentUsageInput: "입력", .agentUsageOutput: "출력", .agentUsageCache: "캐시", .agentUsageAccessibility: "오늘 %2$d개 세션에서 %1$@ 토큰",
            .agentContextLabel: "컨텍스트",
            .agentContextOfLimit: "%2$@ 중 %1$d%%",
            .agentContextTurnsLeft: "약 %d턴 남음",
            .agentContextOverLimit: "한도 초과",
            .agentContextLimitUnknown: "%@ 사용, 한도 알 수 없음",
            .agentContextAccessibility: "컨텍스트 %1$d%% 사용",
        ],
        .japanese: [
            .about: "%@について", .checkForUpdates: "アップデートを確認...", .settings: "設定...", .quit: "%@を終了",
            .shell: "シェル", .newWindow: "新規ウインドウ", .newTab: "新規タブ", .closePaneOrTab: "ペインまたはタブを閉じる",
            .splitVertically: "左右に分割", .splitHorizontally: "上下に分割", .previousTab: "前のタブ", .nextTab: "次のタブ",
            .commandPalette: "コマンドパレット", .findTerminalOutput: "ターミナル出力を検索", .findTerminalOutputPlaceholder: "検索",
            .previousSearchMatch: "前の一致", .nextSearchMatch: "次の一致", .closeSearch: "検索を閉じる",
            .edit: "編集", .cut: "カット", .copy: "コピー", .paste: "ペースト",
            .language: "言語", .systemDefault: "システム言語に従う", .english: "英語", .korean: "韓国語", .japanese: "日本語",
            .searchCommands: "コマンドを検索", .command: "コマンド", .requiresConfirmation: "確認が必要",
            .closePane: "ペインを閉じる", .focusPaneLeft: "左のペインに移動", .focusPaneRight: "右のペインに移動", .focusPaneDown: "下のペインに移動", .focusPaneUp: "上のペインに移動",
            .splitRight: "右に分割", .splitLeft: "左に分割", .splitDown: "下に分割", .splitUp: "上に分割",
            .replayCommandQuestion: "コマンドを再実行しますか？", .openLinkQuestion: "リンクを開きますか？", .cancel: "キャンセル", .open: "開く", .openInBrowser: "ブラウザで開く", .replay: "再実行",
            .pasteLinesQuestion: "%d行をペーストしますか？", .pasteLinesExplanation: "このペーストに含まれるすべての行がシェルで実行される可能性があります。", .pasteConfirm: "ペースト",
            .pasteTooLargeTitle: "ペースト内容が大きすぎます", .pasteTooLargeExplanation: "クリップボードの内容は %d バイトで、ペースト上限の %d バイトを超えています。",
            .updateUnavailableTitle: "自動アップデートを利用できません", .updateUnavailableMessage: "このビルドにはアップデート用の署名がないため、自動ダウンロードとインストールを開始できません。正式リリースではアップデートを自動的にダウンロードしてインストールします。", .ok: "OK",
            .moveToApplicationsTitle: "アプリケーションフォルダに移動しますか？", .moveToApplicationsMessage: "%@ は読み取り専用または一時的な場所から実行されているため、自身をアップデートできません。アプリケーションフォルダに移動して再起動すると解決します。", .moveToApplications: "移動して再起動", .moveToApplicationsLater: "後で",
            .moveToApplicationsFailedTitle: "移動できませんでした", .moveToApplicationsFailedMessage: "アプリケーションフォルダに書き込めません: %@", .translocatedMessage: "macOS が %@ をランダムな読み取り専用のコピーとして実行しているため、自身をアップデートすることも移動することもできません。Finder でアプリをアプリケーションフォルダに移動してから、そこで開いてください。",
            .help: "ヘルプ", .copyDiagnosticsReport: "診断レポートをコピー",
            .diagnosticsReportCopiedTitle: "診断レポートをコピーしました", .diagnosticsReportCopiedMessage: "レポートはクリップボードにあります。バージョン、レンダラー、イベント数のみを含み、ターミナル出力・コマンド・完全なパスは含まれません。",
            .settingsWindow: "%@の設定", .settingsValid: "設定は有効です。", .errors: "エラー", .warnings: "警告",
            .invalidSettingsJSON: "設定JSONが無効です: %@", .settingsLoaded: "%@を読み込みました。変更は自動的に適用されます。%@", .settingsLoadFailed: "読み込みに失敗しました: %@", .settingsNotApplied: "適用されていません。%@", .settingsApplying: "設定を適用しています。%@", .settingsApplied: "%@に適用しました。%@", .settingsApplyFailed: "適用に失敗しました: %@",
            .tmuxSwapPanePrevious: "Tmux: 前のペインと交換", .tmuxSwapPaneNext: "Tmux: 次のペインと交換", .tmuxRotatePanesPrevious: "Tmux: ペインを前方向に回転", .tmuxRotatePanesNext: "Tmux: ペインを次方向に回転",
            .tmuxTogglePaneZoom: "Tmux: ペインのズームを切り替え", .tmuxNextLayout: "Tmux: 次のレイアウト", .tmuxPreviousLayout: "Tmux: 前のレイアウト", .tmuxEvenHorizontalLayout: "Tmux: 左右均等レイアウト",
            .tmuxEvenVerticalLayout: "Tmux: 上下均等レイアウト", .tmuxDetachClient: "Tmux: クライアントをデタッチ",
            .foldCommandOutput: "コマンド出力を折りたたむ", .copyCommandReference: "コマンド参照をコピー", .replayCommand: "コマンドを再実行",
            .foldCommandOutputSubtitle: "コマンド参照を残したまま、完了したコマンドの出力を折りたたみます。", .copyCommandReferenceSubtitle: "生の出力を含めず、安定したコマンド範囲の参照をコピーします。", .replayCommandSubtitle: "確認後、取得したコマンドを再実行します。",
            .view: "表示", .commandHistory: "コマンド履歴", .commandHistoryFilterPlaceholder: "検索", .commandHistoryEmpty: "実行したコマンドがここに表示されます。", .commandHistoryDisabledExplanation: "設定でコマンド履歴がオフになっています。", .commandHistorySectionTitle: "履歴",
            .insertIntoTerminal: "ターミナルに入力", .runAgain: "再実行...", .copyCommand: "コマンドをコピー", .copyChangeDirectoryCommand: "'cd'コマンドをコピー", .revealDirectoryInFinder: "Finderでフォルダを表示",
            .fileExplorer: "ファイルエクスプローラ", .fileExplorerSearchPlaceholder: "ファイルを検索", .fileExplorerSegmentName: "名前", .fileExplorerSegmentContent: "内容",
            .refresh: "再読み込み", .revealInFinder: "Finderで表示", .copyPath: "パスをコピー", .insertPathIntoTerminal: "ターミナルにパスを挿入",
            .editorBinaryFile: "バイナリファイル", .editorFileTooLarge: "ファイルが大きすぎます", .editorLoadFailed: "ファイルを開けませんでした",
            .unsavedChangesQuestion: "\"%@\"の変更内容を保存しますか？", .save: "保存", .discardChanges: "保存しない",
            .agentSessions: "エージェントセッション", .agentSessionsSectionTitle: "エージェントセッション", .agentSessionsFilterPlaceholder: "セッションを検索",
            .agentSessionsEmpty: "このMacに保存されたAIエージェントのセッションがここに表示されます。", .agentSessionsDisabledExplanation: "設定でエージェントセッションのインデックスがオフになっています。",
            .insertResumeCommand: "再開コマンドを入力", .copyResumeCommand: "再開コマンドをコピー", .copySessionIdentifier: "セッションIDをコピー", .copyTranscriptPath: "記録のパスをコピー",
            .revealTranscriptInFinder: "Finderで記録を表示", .openDirectoryInExplorer: "エクスプローラパネルでフォルダを開く",
            .fileExplorerRemoteTitle: "リモートディレクトリ", .fileExplorerRemoteExplanation: "%@ は別のマシン上にあります。エクスプローラはローカルファイルのみを表示します。",
            .agentStatusWorking: "作業中", .agentStatusWaitingForInput: "入力待ち", .agentStatusBlocked: "ブロック中", .agentStatusDone: "完了",
            .quickCommands: "クイックコマンド", .quickCommandsMenuTitle: "クイックコマンド", .quickCommandsEditorTitle: "クイックコマンド", .quickCommandsEmptyState: "クイックコマンドがありません。",
            .quickCommandsPaletteCategory: "クイックコマンド", .quickCommandScopeGlobal: "すべてのディレクトリ", .quickCommandScopeDirectory: "%@ のみ",
            .quickCommandActionTerminalCommand: "ターミナルコマンド", .quickCommandActionAgentPrompt: "エージェントプロンプト",
            .quickCommandInsertsOnly: "実行せずに入力", .quickCommandRunsImmediately: "すぐに実行",
            .quickCommandColumnName: "名前", .quickCommandColumnScope: "範囲", .quickCommandColumnAction: "動作",
            .quickCommandFieldName: "名前", .quickCommandFieldCommandText: "コマンドテキスト", .quickCommandFieldScopeDirectory: "このディレクトリのみ",
            .quickCommandFieldAppendEnter: "入力後に Return を押す (コマンドを実行)", .quickCommandFieldShortcut: "ショートカット",
            .quickCommandAdd: "追加", .quickCommandRemove: "削除", .quickCommandDone: "完了",
            .quickCommandChooseDirectory: "選択…", .quickCommandClearDirectory: "すべてのディレクトリ", .quickCommandUntitled: "無題のコマンド",
            .quickCommandSeedGitStatus: "Git ステータス", .quickCommandSeedGitDiffStat: "Git 差分サマリ",
            .quickCommandSeedGitLogGraph: "Git ロググラフ", .quickCommandSeedClaudeResume: "Claude セッションを再開",
            .openTranscript: "記録を開く", .transcriptEmpty: "この記録にはまだ読み取れるレコードがありません。",
            .transcriptReadOnly: "読み取り専用", .transcriptOlderRecordsHidden: "古いレコードは表示されません。",
            .transcriptRoleUser: "あなた", .transcriptRoleAgent: "エージェント", .transcriptRoleTool: "ツール", .transcriptRoleSystem: "システム",
            .collapseAllToolRuns: "すべてのツール実行を折りたたむ",
            .statusBarAgentIdle: "待機", .statusBarAgentWorking: "作業中", .statusBarAgentNeedsInput: "入力待ち", .statusBarAgentBlocked: "ブロック",
            .statusBarNoAgent: "エージェントなし", .statusBarConnectAnAgent: "エージェントを接続",
            .statusBarConnectAnAgentTooltip: "エージェント状態フックがオフです。環境設定で有効にしてください。",
            .statusBarEnableStatusHooksTitle: "エージェント状態フックを有効にしますか？",
            .statusBarEnableStatusHooksMessage: "エージェント状態の報告はオプトインです。環境設定で有効にすると状態がここに表示されます。",
            .statusBarOpenPreferences: "環境設定を開く",
            .statusBarHistoryTitle: "最近のエージェント状態", .statusBarResumeLastSession: "前回のセッションを再開",
            .statusBarProcessUsageTitle: "プロセス使用量",
            .statusBarMemoryDescription: "常駐メモリ(RSS)の合計です。共有またはエイリアスされたページは複数のプロセスに重複して計上されることがあります。",
            .statusBarQuitProcess: "プロセスを終了", .statusBarQuitProcessTitle: "このプロセスを終了しますか？",
            .statusBarQuitProcessMessage: "ペインのシェルプロセスツリーに終了を要求し、応答がなければ強制終了します。保存していない作業は失われます。",
            .statusBarQuitProcessConfirm: "終了", .statusBarNoProcesses: "サンプリング中のペインプロセスはありません。",
            .agentUsageToday: "今日", .agentUsageInput: "入力", .agentUsageOutput: "出力", .agentUsageCache: "キャッシュ", .agentUsageAccessibility: "本日 %2$d セッションで %1$@ トークン",
            .agentContextLabel: "コンテキスト",
            .agentContextOfLimit: "%2$@ 中 %1$d%%",
            .agentContextTurnsLeft: "残り約 %d ターン",
            .agentContextOverLimit: "上限超過",
            .agentContextLimitUnknown: "%@ 使用、上限不明",
            .agentContextAccessibility: "コンテキスト %1$d%% 使用",
        ],
    ]
}
