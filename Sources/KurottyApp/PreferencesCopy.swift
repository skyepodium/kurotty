import Foundation

enum PreferencesCopy {
    enum Key {
        case settingsTitle, terminalCategory, appearanceCategory, windowCategory
        case searchPlaceholder, searchNoResults
        case terminalTitle, terminalSubtitle, shellSection, shellSectionHelp, workingDirectory
        case textSection, textSectionHelp, font, fontSize, historySection, historySectionHelp, scrollback, lines
        case editorSection, editorSectionHelp, editorFontSize, editorWrap, editorWrapCheckboxTitle
        case commandHistory, commandHistoryCheckboxTitle
        case agentSessionIndex, agentSessionIndexCheckboxTitle
        case hideMouseCursor, hideMouseCursorCheckboxTitle
        case confirmMultilinePaste, confirmMultilinePasteCheckboxTitle
        case confirmClose, confirmCloseCheckboxTitle
        case perProjectHistory, perProjectHistoryCheckboxTitle
        case agentStatusHooks, agentStatusHooksCheckboxTitle
        case restoreScrollback, restoreScrollbackCheckboxTitle
        case statusBar, statusBarCheckboxTitle
        case statusBarAgent, statusBarAgentCheckboxTitle
        case statusBarWorktree, statusBarWorktreeCheckboxTitle
        case statusBarQuota, statusBarQuotaCheckboxTitle
        case statusBarResources, statusBarResourcesCheckboxTitle
        case commandProgress, commandProgressCheckboxTitle
        case menuBarExtra, menuBarExtraCheckboxTitle
        case promptNavigatorRail, promptNavigatorRailCheckboxTitle
        case quickCommandsSection, quickCommandsSectionHelp, quickCommands, quickCommandsButtonTitle
        case appearanceTitle, appearanceSubtitle, themeSection, themeSectionHelp, theme
        case interfaceSection, interfaceSectionHelp, uiTextScale
        case panePadding, paneBorder, paneBorderNone, paneBorderHairline, paneBorderActive
        case inactivePaneDimming, inactivePaneDimmingCheckboxTitle
        case themeKurotty, themeLightty, themeNacre, themeCustom, customColors, customColorsHelp
        case importThemeButtonTitle, themeImported, themeImportFailed
        case themeImportUnrecognized, themeImportIncomplete
        case foreground, background, cursor, ansiPalette
        case windowTitle, windowSubtitle, windowSizeSection, windowSizeHelp, width, height
        case loaded, loadFailed, saving, saved, saveFailed
    }

    static func string(_ key: Key, language: AppLanguage) -> String {
        translations[language]?[key] ?? translations[.english]![key]!
    }

    static func ansiColorName(_ index: Int, language: AppLanguage) -> String {
        let names: [AppLanguage: [String]] = [
            .english: ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White", "Bright black", "Bright red", "Bright green", "Bright yellow", "Bright blue", "Bright magenta", "Bright cyan", "Bright white"],
            .korean: ["검정", "빨강", "초록", "노랑", "파랑", "자홍", "청록", "흰색", "밝은 검정", "밝은 빨강", "밝은 초록", "밝은 노랑", "밝은 파랑", "밝은 자홍", "밝은 청록", "밝은 흰색"],
            .japanese: ["黒", "赤", "緑", "黄", "青", "マゼンタ", "シアン", "白", "明るい黒", "明るい赤", "明るい緑", "明るい黄", "明るい青", "明るいマゼンタ", "明るいシアン", "明るい白"],
        ]
        let localized = names[language] ?? names[.english]!
        guard localized.indices.contains(index) else { return "ANSI \(index)" }
        return localized[index]
    }

    private static let translations: [AppLanguage: [Key: String]] = [
        .english: [
            .settingsTitle: "Settings", .terminalCategory: "Terminal", .appearanceCategory: "Appearance", .windowCategory: "Window",
            .searchPlaceholder: "Search settings", .searchNoResults: "No setting matches “%@”.",
            .terminalTitle: "Terminal", .terminalSubtitle: "Configure new shell sessions, text, and history.",
            .shellSection: "Shell", .shellSectionHelp: "The working directory is used for new terminal sessions.", .workingDirectory: "Working directory",
            .textSection: "Text", .textSectionHelp: "Font changes apply to open terminal surfaces.", .font: "Font", .fontSize: "Font size",
            .editorSection: "Editor", .editorSectionHelp: "Applies to open editor tabs as well as new ones.", .editorFontSize: "Font size", .editorWrap: "Line wrap", .editorWrapCheckboxTitle: "Fold long lines to the pane width instead of scrolling",
            .historySection: "History", .historySectionHelp: "Limit retained scrollback to keep memory use predictable.", .scrollback: "Scrollback", .lines: "lines",
            .commandHistory: "Command history", .commandHistoryCheckboxTitle: "Record commands for the Command History panel",
            .agentSessionIndex: "Agent sessions", .agentSessionIndexCheckboxTitle: "Index AI agent sessions stored on this Mac (read-only)",
            .hideMouseCursor: "Pointer", .hideMouseCursorCheckboxTitle: "Hide the mouse pointer while typing",
            .confirmMultilinePaste: "Paste", .confirmMultilinePasteCheckboxTitle: "Ask before pasting more than one line",
            .confirmClose: "Closing", .confirmCloseCheckboxTitle: "Ask before closing a tab or window with a running process",
            .perProjectHistory: "Shell history", .perProjectHistoryCheckboxTitle: "Keep a separate shell history per project (new sessions)",
            .agentStatusHooks: "Agent status hooks", .agentStatusHooksCheckboxTitle: "Let Claude Code and Codex report status through Kurotty's local hook (asks once per agent before editing its settings)",
            .restoreScrollback: "Restore scrollback", .restoreScrollbackCheckboxTitle: "Restore each pane's scrollback text at launch (display only, applies next launch)",
            .statusBar: "Status bar", .statusBarCheckboxTitle: "Show the bottom status bar with agent state and pane resource usage",
            .statusBarAgent: "Status agent", .statusBarAgentCheckboxTitle: "Show agent state in the status bar",
            .statusBarWorktree: "Status worktree", .statusBarWorktreeCheckboxTitle: "Show the active pane's git worktree in the status bar",
            .statusBarQuota: "Status quota", .statusBarQuotaCheckboxTitle: "Show indexed agent quota in the status bar",
            .statusBarResources: "Status resources", .statusBarResourcesCheckboxTitle: "Show memory and CPU in the status bar",
            .commandProgress: "Command progress", .commandProgressCheckboxTitle: "Show a progress bar at the top of a pane while a command runs",
            .menuBarExtra: "Menu bar", .menuBarExtraCheckboxTitle: "Show a Kurotty icon in the macOS menu bar",
            .promptNavigatorRail: "Prompt navigator", .promptNavigatorRailCheckboxTitle: "Mark each command on a rail down the terminal's right edge",
            .quickCommandsSection: "Quick Commands", .quickCommandsSectionHelp: "Named commands offered in the command palette and the terminal context menu.",
            .quickCommands: "Quick Commands", .quickCommandsButtonTitle: "Edit Quick Commands…",
            .appearanceTitle: "Appearance", .appearanceSubtitle: "Choose a built-in theme or create your own palette.",
            .themeSection: "Terminal theme", .themeSectionHelp: "The sample shows how foreground, ANSI colors, background, and cursor work together.", .theme: "Theme",
            .themeKurotty: "Kurotty", .themeLightty: "Lightty", .themeNacre: "Nacre", .themeCustom: "Custom",
            .interfaceSection: "Interface", .interfaceSectionHelp: "Scales Kurotty's own sidebar, tabs, status bar, and this window. Terminal text keeps its own size.", .uiTextScale: "UI text size",
            .panePadding: "Pane padding", .paneBorder: "Pane border", .paneBorderNone: "None", .paneBorderHairline: "Hairline", .paneBorderActive: "Active accent",
            .inactivePaneDimming: "Inactive panes", .inactivePaneDimmingCheckboxTitle: "Dim panes that do not have focus",
            .customColors: "Custom colors", .customColorsHelp: "Changing any color keeps the full palette as a custom theme.",
            .importThemeButtonTitle: "Import Theme…",
            .themeImported: "Imported \"%@\" as the custom theme.",
            .themeImportFailed: "Could not import theme: %@",
            .themeImportUnrecognized: "The file is not an iTerm2 .itermcolors or Ghostty theme file.",
            .themeImportIncomplete: "The theme is missing colors. All 16 ANSI colors plus foreground and background are required.",
            .foreground: "Text", .background: "Background", .cursor: "Cursor", .ansiPalette: "ANSI palette · normal and bright",
            .windowTitle: "Window", .windowSubtitle: "Set the default size for new windows.",
            .windowSizeSection: "Default window size", .windowSizeHelp: "Existing windows keep their current size.", .width: "Width", .height: "Height",
            .loaded: "Settings loaded. Changes save automatically.", .loadFailed: "Could not load settings: %@", .saving: "Saving changes…", .saved: "All changes saved.", .saveFailed: "Could not save settings: %@",
        ],
        .korean: [
            .settingsTitle: "설정", .terminalCategory: "터미널", .appearanceCategory: "모양", .windowCategory: "윈도우",
            .searchPlaceholder: "설정 검색", .searchNoResults: "“%@”와 일치하는 설정이 없습니다.",
            .terminalTitle: "터미널", .terminalSubtitle: "새 셸 세션과 글꼴, 기록을 설정합니다.",
            .shellSection: "셸", .shellSectionHelp: "새 터미널 세션을 시작할 작업 폴더입니다.", .workingDirectory: "작업 폴더",
            .textSection: "텍스트", .textSectionHelp: "글꼴 변경은 열려 있는 터미널에도 적용됩니다.", .font: "글꼴", .fontSize: "글꼴 크기",
            .editorSection: "에디터", .editorSectionHelp: "열려 있는 에디터 탭에도 함께 적용됩니다.", .editorFontSize: "글꼴 크기", .editorWrap: "줄바꿈", .editorWrapCheckboxTitle: "긴 줄을 가로 스크롤 대신 패널 너비에 맞춰 접기",
            .historySection: "기록", .historySectionHelp: "메모리 사용량을 예측할 수 있도록 스크롤백 보관량을 제한합니다.", .scrollback: "스크롤백", .lines: "줄",
            .commandHistory: "명령 기록", .commandHistoryCheckboxTitle: "명령 기록 패널을 위해 실행한 명령을 저장",
            .agentSessionIndex: "에이전트 세션", .agentSessionIndexCheckboxTitle: "이 Mac에 저장된 AI 에이전트 세션을 색인 (읽기 전용)",
            .confirmMultilinePaste: "붙여넣기", .confirmMultilinePasteCheckboxTitle: "여러 줄을 붙여넣기 전에 확인",
            .confirmClose: "닫기", .confirmCloseCheckboxTitle: "실행 중인 프로세스가 있는 탭이나 윈도우를 닫기 전에 확인",
            .hideMouseCursor: "포인터", .hideMouseCursorCheckboxTitle: "입력하는 동안 마우스 포인터 숨기기",
            .perProjectHistory: "셸 기록", .perProjectHistoryCheckboxTitle: "프로젝트별로 셸 기록을 분리해서 저장 (새 세션부터)",
            .restoreScrollback: "스크롤백 복원", .restoreScrollbackCheckboxTitle: "실행 시 각 패널의 스크롤백 텍스트를 복원 (표시 전용, 다음 실행부터 적용)",
            .statusBar: "상태 표시줄", .statusBarCheckboxTitle: "에이전트 상태와 패널 리소스 사용량을 보여주는 하단 상태 표시줄 표시",
            .statusBarAgent: "상태 에이전트", .statusBarAgentCheckboxTitle: "상태 표시줄에 에이전트 상태 표시",
            .statusBarWorktree: "상태 워크트리", .statusBarWorktreeCheckboxTitle: "상태 표시줄에 활성 패널의 git 워크트리 표시",
            .statusBarQuota: "상태 할당량", .statusBarQuotaCheckboxTitle: "상태 표시줄에 색인된 에이전트 할당량 표시",
            .statusBarResources: "상태 리소스", .statusBarResourcesCheckboxTitle: "상태 표시줄에 메모리와 CPU 표시",
            .commandProgress: "명령 진행 표시", .commandProgressCheckboxTitle: "명령이 실행되는 동안 패널 상단에 진행 막대 표시",
            .menuBarExtra: "메뉴 막대", .menuBarExtraCheckboxTitle: "macOS 메뉴 막대에 Kurotty 아이콘 표시",
            .promptNavigatorRail: "프롬프트 내비게이터", .promptNavigatorRailCheckboxTitle: "터미널 오른쪽 가장자리 레일에 명령마다 표시 남기기",
            .agentStatusHooks: "에이전트 상태 훅", .agentStatusHooksCheckboxTitle: "Kurotty의 로컬 훅으로 Claude Code와 Codex가 상태를 보고하도록 허용 (각 에이전트 설정을 수정하기 전에 한 번씩 확인)",
            .quickCommandsSection: "빠른 명령", .quickCommandsSectionHelp: "명령 팔레트와 터미널 컨텍스트 메뉴에 표시되는 이름 붙인 명령입니다.",
            .quickCommands: "빠른 명령", .quickCommandsButtonTitle: "빠른 명령 편집…",
            .appearanceTitle: "모양", .appearanceSubtitle: "기본 테마를 선택하거나 직접 색상 팔레트를 만들 수 있습니다.",
            .themeSection: "터미널 테마", .themeSectionHelp: "미리보기에서 글자, ANSI 색상, 배경과 커서가 어떻게 적용되는지 확인할 수 있습니다.", .theme: "테마",
            .themeKurotty: "Kurotty", .themeLightty: "Lightty", .themeNacre: "Nacre", .themeCustom: "커스텀",
            .interfaceSection: "인터페이스", .interfaceSectionHelp: "Kurotty의 사이드바, 탭, 상태 표시줄과 이 창의 크기를 조절합니다. 터미널 글자 크기는 그대로 유지됩니다.", .uiTextScale: "UI 글자 크기",
            .panePadding: "패널 여백", .paneBorder: "패널 테두리", .paneBorderNone: "없음", .paneBorderHairline: "가는 선", .paneBorderActive: "활성 강조",
            .inactivePaneDimming: "비활성 패널", .inactivePaneDimmingCheckboxTitle: "포커스가 없는 패널을 어둡게 표시",
            .customColors: "커스텀 색상", .customColorsHelp: "색상을 하나라도 변경하면 전체 팔레트를 커스텀 테마로 보관합니다.",
            .importThemeButtonTitle: "테마 가져오기…",
            .themeImported: "\"%@\"을(를) 커스텀 테마로 가져왔습니다.",
            .themeImportFailed: "테마를 가져올 수 없습니다: %@",
            .themeImportUnrecognized: "iTerm2 .itermcolors 또는 Ghostty 테마 파일이 아닙니다.",
            .themeImportIncomplete: "테마에 색상이 부족합니다. ANSI 16색과 글자·배경 색상이 모두 필요합니다.",
            .foreground: "글자", .background: "배경", .cursor: "커서", .ansiPalette: "ANSI 팔레트 · 기본 및 밝은 색",
            .windowTitle: "윈도우", .windowSubtitle: "새 윈도우의 기본 크기를 설정합니다.",
            .windowSizeSection: "기본 윈도우 크기", .windowSizeHelp: "이미 열린 윈도우의 크기는 유지됩니다.", .width: "너비", .height: "높이",
            .loaded: "설정을 불러왔습니다. 변경 사항은 자동으로 저장됩니다.", .loadFailed: "설정을 불러올 수 없습니다: %@", .saving: "변경 사항 저장 중…", .saved: "모든 변경 사항을 저장했습니다.", .saveFailed: "설정을 저장할 수 없습니다: %@",
        ],
        .japanese: [
            .settingsTitle: "設定", .terminalCategory: "ターミナル", .appearanceCategory: "外観", .windowCategory: "ウインドウ",
            .searchPlaceholder: "設定を検索", .searchNoResults: "「%@」に一致する設定はありません。",
            .terminalTitle: "ターミナル", .terminalSubtitle: "新しいシェルセッション、テキスト、履歴を設定します。",
            .shellSection: "シェル", .shellSectionHelp: "新しいターミナルセッションで使用する作業フォルダです。", .workingDirectory: "作業フォルダ",
            .textSection: "テキスト", .textSectionHelp: "フォントの変更は開いているターミナルにも適用されます。", .font: "フォント", .fontSize: "フォントサイズ",
            .editorSection: "エディタ", .editorSectionHelp: "開いているエディタタブにも適用されます。", .editorFontSize: "フォントサイズ", .editorWrap: "行の折り返し", .editorWrapCheckboxTitle: "長い行を横スクロールせずペイン幅で折り返す",
            .historySection: "履歴", .historySectionHelp: "メモリ使用量を予測可能にするため、スクロールバックの保持量を制限します。", .scrollback: "スクロールバック", .lines: "行",
            .commandHistory: "コマンド履歴", .commandHistoryCheckboxTitle: "コマンド履歴パネルのために実行したコマンドを保存",
            .agentSessionIndex: "エージェントセッション", .agentSessionIndexCheckboxTitle: "このMacに保存されたAIエージェントのセッションをインデックス（読み取り専用）",
            .confirmMultilinePaste: "ペースト", .confirmMultilinePasteCheckboxTitle: "複数行をペーストする前に確認",
            .confirmClose: "閉じる", .confirmCloseCheckboxTitle: "実行中のプロセスがあるタブやウインドウを閉じる前に確認",
            .hideMouseCursor: "ポインタ", .hideMouseCursorCheckboxTitle: "入力中はマウスポインタを隠す",
            .perProjectHistory: "シェル履歴", .perProjectHistoryCheckboxTitle: "プロジェクトごとにシェル履歴を分ける（新しいセッションから）",
            .restoreScrollback: "スクロールバックを復元", .restoreScrollbackCheckboxTitle: "起動時に各ペインのスクロールバックを復元 (表示のみ、次回起動から適用)",
            .statusBar: "ステータスバー", .statusBarCheckboxTitle: "エージェント状態とペインのリソース使用量を表示する下部ステータスバーを表示",
            .statusBarAgent: "ステータスのエージェント", .statusBarAgentCheckboxTitle: "ステータスバーにエージェント状態を表示",
            .statusBarWorktree: "ステータスのワークツリー", .statusBarWorktreeCheckboxTitle: "ステータスバーにアクティブペインのgitワークツリーを表示",
            .statusBarQuota: "ステータスの割り当て", .statusBarQuotaCheckboxTitle: "ステータスバーにインデックス済みエージェント割り当てを表示",
            .statusBarResources: "ステータスのリソース", .statusBarResourcesCheckboxTitle: "ステータスバーにメモリとCPUを表示",
            .commandProgress: "コマンドの進行状況", .commandProgressCheckboxTitle: "コマンドの実行中にペイン上部へ進行バーを表示",
            .menuBarExtra: "メニューバー", .menuBarExtraCheckboxTitle: "macOSのメニューバーにKurottyのアイコンを表示",
            .promptNavigatorRail: "プロンプトナビゲータ", .promptNavigatorRailCheckboxTitle: "ターミナル右端のレールにコマンドごとの目印を表示",
            .agentStatusHooks: "エージェント状態フック", .agentStatusHooksCheckboxTitle: "Kurottyのローカルフック経由でClaude CodeとCodexが状態を報告できるようにする（各エージェントの設定を変更する前に一度ずつ確認）",
            .quickCommandsSection: "クイックコマンド", .quickCommandsSectionHelp: "コマンドパレットとターミナルのコンテキストメニューに表示される名前付きコマンドです。",
            .quickCommands: "クイックコマンド", .quickCommandsButtonTitle: "クイックコマンドを編集…",
            .appearanceTitle: "外観", .appearanceSubtitle: "組み込みテーマを選ぶか、独自のカラーパレットを作成できます。",
            .themeSection: "ターミナルテーマ", .themeSectionHelp: "プレビューで文字、ANSIカラー、背景、カーソルの適用を確認できます。", .theme: "テーマ",
            .themeKurotty: "Kurotty", .themeLightty: "Lightty", .themeNacre: "Nacre", .themeCustom: "カスタム",
            .interfaceSection: "インターフェース", .interfaceSectionHelp: "Kurotty自身のサイドバー、タブ、ステータスバー、そしてこの画面の大きさを調整します。ターミナルの文字サイズはそのままです。", .uiTextScale: "UIの文字サイズ",
            .panePadding: "ペイン余白", .paneBorder: "ペイン境界線", .paneBorderNone: "なし", .paneBorderHairline: "細線", .paneBorderActive: "アクティブアクセント",
            .inactivePaneDimming: "非アクティブペイン", .inactivePaneDimmingCheckboxTitle: "フォーカスしていないペインを暗く表示",
            .customColors: "カスタムカラー", .customColorsHelp: "いずれかの色を変更すると、パレット全体をカスタムテーマとして保持します。",
            .importThemeButtonTitle: "テーマを読み込む…",
            .themeImported: "\"%@\"をカスタムテーマとして読み込みました。",
            .themeImportFailed: "テーマを読み込めません: %@",
            .themeImportUnrecognized: "iTerm2 の .itermcolors または Ghostty のテーマファイルではありません。",
            .themeImportIncomplete: "テーマの色が不足しています。ANSI 16色と文字・背景の色がすべて必要です。",
            .foreground: "文字", .background: "背景", .cursor: "カーソル", .ansiPalette: "ANSIパレット・標準と明色",
            .windowTitle: "ウインドウ", .windowSubtitle: "新しいウインドウのデフォルトサイズを設定します。",
            .windowSizeSection: "デフォルトサイズ", .windowSizeHelp: "開いているウインドウのサイズは変わりません。", .width: "幅", .height: "高さ",
            .loaded: "設定を読み込みました。変更は自動的に保存されます。", .loadFailed: "設定を読み込めません: %@", .saving: "変更を保存中…", .saved: "すべての変更を保存しました。", .saveFailed: "設定を保存できません: %@",
        ],
    ]
}
