import Foundation

// MARK: - Staged design tokens

/// Numeric tokens for the status bar, staged here because `DesignTokens.swift`
/// is owned by another change. Migrate verbatim into
/// `DesignTokens.Component` (sizes) and keep the unit suffixes.
enum TerminalStatusBarTokens {
    static let heightPX: CGFloat = 24
    static let horizontalInsetPX = DesignTokens.Space.x4PX
    static let segmentGroupGapPX = DesignTokens.Space.x4PX
    static let segmentPaddingXPX = DesignTokens.Space.x2PX
    static let segmentCornerRadiusPX = DesignTokens.Radius.xsPX
    static let fontSizePT = DesignTokens.Typography.statusBar.sizePT
    static let iconPointSizePT: CGFloat = 11
    static let dotSizePX: CGFloat = 6
    static let hollowRingLineWidthPX: CGFloat = 1.5
    static let hollowRingAlphaRATIO: CGFloat = 0.55
    static let dotGlyphGapPX = DesignTokens.Space.x1PX
    static let glyphLabelGapPX = DesignTokens.Space.x2PX
    static let labelDetailGapPX = DesignTokens.Space.x2PX
    static let iconValueGapPX = DesignTokens.Space.x1PX
    static let metricGapPX = DesignTokens.Space.x4PX
    static let agentLabelMaxWidthPX: CGFloat = 160
    static let agentDetailMaxWidthPX: CGFloat = 96
    static let memoryValueMinWidthPX: CGFloat = 48
    static let cpuValueMinWidthPX: CGFloat = 40
    static let spinnerSizePX: CGFloat = 12
    static let badgeHeightPX: CGFloat = 14
    static let badgeTextInsetXPX = DesignTokens.Space.x1PX
    static let badgeCornerRadiusPX: CGFloat = 3
    static let badgeFontSizePT: CGFloat = 9
    static let hoverFillAlphaRATIO: CGFloat = 0.07
    static let pressFillAlphaRATIO: CGFloat = 0.14
    static let valueCrossfadeSeconds: CFTimeInterval = 0.12
    static let samplingIntervalSeconds: TimeInterval = 2.0
    static let killGracePeriodSeconds: TimeInterval = 3.0
    static let popoverWidthPX: CGFloat = 320
    static let popoverInsetPX = DesignTokens.Space.x4PX
    static let popoverRowHeightPX: CGFloat = 22
    static let popoverRowGapPX = DesignTokens.Space.x1PX
    static let popoverMaximumRowCount = 12
    /// Responsive-truncation breakpoints, widest first.
    static let agentDetailBreakpointPX: CGFloat = 560
    static let cpuMetricBreakpointPX: CGFloat = 440
    static let agentLabelBreakpointPX: CGFloat = 340
    static let iconOnlyBreakpointPX: CGFloat = 240
    /// Percent thresholds for value coloring.
    static let warningPercentRATIO: Double = 80
    static let errorPercentRATIO: Double = 92
    static let maximumCPUPercentRATIO: Double = 100
    static let bytesPerKilobyteRATIO: Double = 1024
    /// Bound on how deep a pane's process subtree is walked per sample.
    static let processTreeMaximumDepthCOUNT = 6
    static let processTreeMaximumProcessCOUNT = 256
}

/// SF Symbol names used by the bar.
enum TerminalStatusBarSymbols {
    static let memory = "memorychip"
    static let cpu = "cpu"
    static let disconnected = "bolt.slash"
    static let agent = "sparkles"
}

// MARK: - Staged strings

/// Copy staged here because `AppLocalization.swift` is owned by another change.
/// Every key below should move into `AppLocalization.Key` with the same English
/// and Korean text; `string(_:language:)` mirrors the existing lookup shape.
enum TerminalStatusBarStrings {
    enum Key: String, CaseIterable {
        case agentIdle
        case agentWorking
        case agentNeedsInput
        case agentBlocked
        case noAgent
        case connectAnAgent
        case connectAnAgentTooltip
        case enableStatusHooksTitle
        case enableStatusHooksMessage
        case openPreferences
        case cancel
        case statusHistoryTitle
        case resumeLastSession
        case processUsageTitle
        case quitProcess
        case quitProcessTitle
        case quitProcessMessage
        case quitProcessConfirm
        case noProcesses
    }

    static let memoryColumnLabel = "RSS"
    static let memorySummaryLabel = "Σ RSS"
    static let memoryDescription =
        "Summed resident set size (RSS). Shared or aliased pages can appear in more than one process."
    static let memoryPrefix = "RAM"
    static let cpuPrefix = "CPU"
    static let summarySeparator = "·"
    static let labelSeparator = "·"
    static let detailSeparator = "—"
    static let unavailableValue = "—"
    static let kilobyteUnit = "KB"
    static let megabyteUnit = "MB"
    static let gigabyteUnit = "GB"
    static let percentUnit = "%"

    private static let english: [Key: String] = [
        .agentIdle: "Idle",
        .agentWorking: "Working",
        .agentNeedsInput: "Needs input",
        .agentBlocked: "Blocked",
        .noAgent: "No agent",
        .connectAnAgent: "Connect an agent",
        .connectAnAgentTooltip: "Agent status hooks are off. Open Preferences to enable them.",
        .enableStatusHooksTitle: "Enable agent status hooks?",
        .enableStatusHooksMessage:
            "Agent status reporting is opt-in. Enable it in Preferences to see live agent state here.",
        .openPreferences: "Open Preferences",
        .cancel: "Cancel",
        .statusHistoryTitle: "Recent agent status",
        .resumeLastSession: "Resume last session",
        .processUsageTitle: "Process usage",
        .quitProcess: "Quit process",
        .quitProcessTitle: "Quit this process?",
        .quitProcessMessage:
            "The pane's shell process tree is asked to terminate, then force-quit if it does not exit. Unsaved work in that pane is lost.",
        .quitProcessConfirm: "Quit",
        .noProcesses: "No pane processes are being sampled.",
    ]

    private static let korean: [Key: String] = [
        .agentIdle: "대기",
        .agentWorking: "작업 중",
        .agentNeedsInput: "입력 필요",
        .agentBlocked: "차단됨",
        .noAgent: "에이전트 없음",
        .connectAnAgent: "에이전트 연결",
        .connectAnAgentTooltip: "에이전트 상태 후크가 꺼져 있습니다. 환경설정에서 켜세요.",
        .enableStatusHooksTitle: "에이전트 상태 후크를 켤까요?",
        .enableStatusHooksMessage: "에이전트 상태 보고는 선택 기능입니다. 환경설정에서 켜면 여기에 상태가 표시됩니다.",
        .openPreferences: "환경설정 열기",
        .cancel: "취소",
        .statusHistoryTitle: "최근 에이전트 상태",
        .resumeLastSession: "마지막 세션 이어하기",
        .processUsageTitle: "프로세스 사용량",
        .quitProcess: "프로세스 종료",
        .quitProcessTitle: "이 프로세스를 종료할까요?",
        .quitProcessMessage: "패널의 셸 프로세스 트리에 종료를 요청하고, 응답이 없으면 강제 종료합니다. 저장하지 않은 작업은 사라집니다.",
        .quitProcessConfirm: "종료",
        .noProcesses: "샘플링 중인 패널 프로세스가 없습니다.",
    ]

    private static let japanese: [Key: String] = [
        .agentIdle: "待機",
        .agentWorking: "作業中",
        .agentNeedsInput: "入力待ち",
        .agentBlocked: "ブロック",
        .noAgent: "エージェントなし",
        .connectAnAgent: "エージェントを接続",
        .connectAnAgentTooltip: "エージェント状態フックがオフです。環境設定で有効にしてください。",
        .enableStatusHooksTitle: "エージェント状態フックを有効にしますか？",
        .enableStatusHooksMessage: "エージェント状態の報告はオプトインです。環境設定で有効にすると状態がここに表示されます。",
        .openPreferences: "環境設定を開く",
        .cancel: "キャンセル",
        .statusHistoryTitle: "最近のエージェント状態",
        .resumeLastSession: "前回のセッションを再開",
        .processUsageTitle: "プロセス使用量",
        .quitProcess: "プロセスを終了",
        .quitProcessTitle: "このプロセスを終了しますか？",
        .quitProcessMessage: "ペインのシェルプロセスツリーに終了を要求し、応答がなければ強制終了します。保存していない作業は失われます。",
        .quitProcessConfirm: "終了",
        .noProcesses: "サンプリング中のペインプロセスはありません。",
    ]

    private static let translations: [AppLanguage: [Key: String]] = [
        .english: english,
        .korean: korean,
        .japanese: japanese,
    ]

    static func string(_ key: Key, language: AppLanguage = AppLocalization.language) -> String {
        translations[language]?[key] ?? english[key] ?? key.rawValue
    }

    static func stateLabel(
        for state: AgentActivityState,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        switch state {
        case .working:
            return string(.agentWorking, language: language)
        case .waitingForInput:
            return string(.agentNeedsInput, language: language)
        case .blocked:
            return string(.agentBlocked, language: language)
        case .done:
            return string(.agentIdle, language: language)
        }
    }
}
