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
    case commandPalette, edit, cut, copy, paste
    case language, systemDefault, english, korean, japanese
    case searchCommands, command, requiresConfirmation
    case closePane, focusPaneLeft, focusPaneRight, focusPaneDown, focusPaneUp
    case splitRight, splitLeft, splitDown, splitUp
    case replayCommandQuestion, openLinkQuestion, cancel, open, openInBrowser, replay
    case updateUnavailableTitle, updateUnavailableMessage, ok
    case settingsWindow, settingsValid, errors, warnings
    case invalidSettingsJSON, settingsLoaded, settingsLoadFailed, settingsNotApplied, settingsApplying, settingsApplied, settingsApplyFailed
    case tmuxSwapPanePrevious, tmuxSwapPaneNext, tmuxRotatePanesPrevious, tmuxRotatePanesNext
    case tmuxTogglePaneZoom, tmuxNextLayout, tmuxPreviousLayout, tmuxEvenHorizontalLayout
    case tmuxEvenVerticalLayout, tmuxDetachClient
    case foldCommandOutput, copyCommandReference, replayCommand
    case foldCommandOutputSubtitle, copyCommandReferenceSubtitle, replayCommandSubtitle
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
            .commandPalette: "Command Palette", .edit: "Edit", .cut: "Cut", .copy: "Copy", .paste: "Paste",
            .language: "Language", .systemDefault: "Follow System Language", .english: "English", .korean: "Korean", .japanese: "Japanese",
            .searchCommands: "Search commands", .command: "Command", .requiresConfirmation: "Requires confirmation",
            .closePane: "Close Pane", .focusPaneLeft: "Focus Pane Left", .focusPaneRight: "Focus Pane Right", .focusPaneDown: "Focus Pane Down", .focusPaneUp: "Focus Pane Up",
            .splitRight: "Split Right", .splitLeft: "Split Left", .splitDown: "Split Down", .splitUp: "Split Up",
            .replayCommandQuestion: "Replay Command?", .openLinkQuestion: "Open Link?", .cancel: "Cancel", .open: "Open", .openInBrowser: "Open in Browser", .replay: "Replay",
            .updateUnavailableTitle: "Automatic Updates Unavailable", .updateUnavailableMessage: "This build is not signed for updates, so automatic download and installation cannot start. Official release builds download and install updates automatically.", .ok: "OK",
            .settingsWindow: "%@ Settings", .settingsValid: "Settings valid.", .errors: "Errors", .warnings: "Warnings",
            .invalidSettingsJSON: "Settings JSON is invalid: %@", .settingsLoaded: "Loaded %@. Edits apply automatically. %@", .settingsLoadFailed: "Load failed: %@", .settingsNotApplied: "Not applied. %@", .settingsApplying: "Applying settings. %@", .settingsApplied: "Applied %@. %@", .settingsApplyFailed: "Apply failed: %@",
            .tmuxSwapPanePrevious: "Tmux: Swap Pane Previous", .tmuxSwapPaneNext: "Tmux: Swap Pane Next", .tmuxRotatePanesPrevious: "Tmux: Rotate Panes Previous", .tmuxRotatePanesNext: "Tmux: Rotate Panes Next",
            .tmuxTogglePaneZoom: "Tmux: Toggle Pane Zoom", .tmuxNextLayout: "Tmux: Next Layout", .tmuxPreviousLayout: "Tmux: Previous Layout", .tmuxEvenHorizontalLayout: "Tmux: Even Horizontal Layout",
            .tmuxEvenVerticalLayout: "Tmux: Even Vertical Layout", .tmuxDetachClient: "Tmux: Detach Client",
            .foldCommandOutput: "Fold Command Output", .copyCommandReference: "Copy Command Reference", .replayCommand: "Replay Command",
            .foldCommandOutputSubtitle: "Collapse a completed command's output while keeping the command reference.", .copyCommandReferenceSubtitle: "Copy a stable command-span reference without including raw output.", .replayCommandSubtitle: "Run the captured command again after explicit confirmation.",
        ],
        .korean: [
            .about: "%@ 정보", .checkForUpdates: "업데이트 확인...", .settings: "설정...", .quit: "%@ 종료",
            .shell: "셸", .newWindow: "새 윈도우", .newTab: "새 탭", .closePaneOrTab: "패널 또는 탭 닫기",
            .splitVertically: "좌우로 분할", .splitHorizontally: "상하로 분할", .previousTab: "이전 탭", .nextTab: "다음 탭",
            .commandPalette: "명령 팔레트", .edit: "편집", .cut: "오려두기", .copy: "복사", .paste: "붙여넣기",
            .language: "언어", .systemDefault: "시스템 언어 따라가기", .english: "영어", .korean: "한국어", .japanese: "일본어",
            .searchCommands: "명령 검색", .command: "명령", .requiresConfirmation: "확인 필요",
            .closePane: "패널 닫기", .focusPaneLeft: "왼쪽 패널로 이동", .focusPaneRight: "오른쪽 패널로 이동", .focusPaneDown: "아래 패널로 이동", .focusPaneUp: "위 패널로 이동",
            .splitRight: "오른쪽으로 분할", .splitLeft: "왼쪽으로 분할", .splitDown: "아래로 분할", .splitUp: "위로 분할",
            .replayCommandQuestion: "명령을 다시 실행할까요?", .openLinkQuestion: "링크를 열까요?", .cancel: "취소", .open: "열기", .openInBrowser: "브라우저에서 열기", .replay: "다시 실행",
            .updateUnavailableTitle: "자동 업데이트를 사용할 수 없습니다", .updateUnavailableMessage: "이 빌드에는 업데이트 서명이 없어 자동 다운로드와 설치를 시작할 수 없습니다. 정식 배포 빌드에서는 업데이트를 자동으로 내려받고 설치합니다.", .ok: "확인",
            .settingsWindow: "%@ 설정", .settingsValid: "설정이 유효합니다.", .errors: "오류", .warnings: "경고",
            .invalidSettingsJSON: "설정 JSON이 올바르지 않습니다: %@", .settingsLoaded: "%@을(를) 불러왔습니다. 변경 사항은 자동으로 적용됩니다. %@", .settingsLoadFailed: "불러오기 실패: %@", .settingsNotApplied: "적용되지 않았습니다. %@", .settingsApplying: "설정을 적용하는 중입니다. %@", .settingsApplied: "%@에 적용했습니다. %@", .settingsApplyFailed: "적용 실패: %@",
            .tmuxSwapPanePrevious: "Tmux: 이전 패널과 교체", .tmuxSwapPaneNext: "Tmux: 다음 패널과 교체", .tmuxRotatePanesPrevious: "Tmux: 패널을 이전 방향으로 회전", .tmuxRotatePanesNext: "Tmux: 패널을 다음 방향으로 회전",
            .tmuxTogglePaneZoom: "Tmux: 패널 확대 전환", .tmuxNextLayout: "Tmux: 다음 레이아웃", .tmuxPreviousLayout: "Tmux: 이전 레이아웃", .tmuxEvenHorizontalLayout: "Tmux: 좌우 균등 레이아웃",
            .tmuxEvenVerticalLayout: "Tmux: 상하 균등 레이아웃", .tmuxDetachClient: "Tmux: 클라이언트 분리",
            .foldCommandOutput: "명령 출력 접기", .copyCommandReference: "명령 참조 복사", .replayCommand: "명령 다시 실행",
            .foldCommandOutputSubtitle: "명령 참조는 유지하고 완료된 명령 출력을 접습니다.", .copyCommandReferenceSubtitle: "원본 출력을 제외하고 안정적인 명령 범위 참조를 복사합니다.", .replayCommandSubtitle: "확인 후 캡처한 명령을 다시 실행합니다.",
        ],
        .japanese: [
            .about: "%@について", .checkForUpdates: "アップデートを確認...", .settings: "設定...", .quit: "%@を終了",
            .shell: "シェル", .newWindow: "新規ウインドウ", .newTab: "新規タブ", .closePaneOrTab: "ペインまたはタブを閉じる",
            .splitVertically: "左右に分割", .splitHorizontally: "上下に分割", .previousTab: "前のタブ", .nextTab: "次のタブ",
            .commandPalette: "コマンドパレット", .edit: "編集", .cut: "カット", .copy: "コピー", .paste: "ペースト",
            .language: "言語", .systemDefault: "システム言語に従う", .english: "英語", .korean: "韓国語", .japanese: "日本語",
            .searchCommands: "コマンドを検索", .command: "コマンド", .requiresConfirmation: "確認が必要",
            .closePane: "ペインを閉じる", .focusPaneLeft: "左のペインに移動", .focusPaneRight: "右のペインに移動", .focusPaneDown: "下のペインに移動", .focusPaneUp: "上のペインに移動",
            .splitRight: "右に分割", .splitLeft: "左に分割", .splitDown: "下に分割", .splitUp: "上に分割",
            .replayCommandQuestion: "コマンドを再実行しますか？", .openLinkQuestion: "リンクを開きますか？", .cancel: "キャンセル", .open: "開く", .openInBrowser: "ブラウザで開く", .replay: "再実行",
            .updateUnavailableTitle: "自動アップデートを利用できません", .updateUnavailableMessage: "このビルドにはアップデート用の署名がないため、自動ダウンロードとインストールを開始できません。正式リリースではアップデートを自動的にダウンロードしてインストールします。", .ok: "OK",
            .settingsWindow: "%@の設定", .settingsValid: "設定は有効です。", .errors: "エラー", .warnings: "警告",
            .invalidSettingsJSON: "設定JSONが無効です: %@", .settingsLoaded: "%@を読み込みました。変更は自動的に適用されます。%@", .settingsLoadFailed: "読み込みに失敗しました: %@", .settingsNotApplied: "適用されていません。%@", .settingsApplying: "設定を適用しています。%@", .settingsApplied: "%@に適用しました。%@", .settingsApplyFailed: "適用に失敗しました: %@",
            .tmuxSwapPanePrevious: "Tmux: 前のペインと交換", .tmuxSwapPaneNext: "Tmux: 次のペインと交換", .tmuxRotatePanesPrevious: "Tmux: ペインを前方向に回転", .tmuxRotatePanesNext: "Tmux: ペインを次方向に回転",
            .tmuxTogglePaneZoom: "Tmux: ペインのズームを切り替え", .tmuxNextLayout: "Tmux: 次のレイアウト", .tmuxPreviousLayout: "Tmux: 前のレイアウト", .tmuxEvenHorizontalLayout: "Tmux: 左右均等レイアウト",
            .tmuxEvenVerticalLayout: "Tmux: 上下均等レイアウト", .tmuxDetachClient: "Tmux: クライアントをデタッチ",
            .foldCommandOutput: "コマンド出力を折りたたむ", .copyCommandReference: "コマンド参照をコピー", .replayCommand: "コマンドを再実行",
            .foldCommandOutputSubtitle: "コマンド参照を残したまま、完了したコマンドの出力を折りたたみます。", .copyCommandReferenceSubtitle: "生の出力を含めず、安定したコマンド範囲の参照をコピーします。", .replayCommandSubtitle: "確認後、取得したコマンドを再実行します。",
        ],
    ]
}
