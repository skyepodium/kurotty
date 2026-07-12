import Foundation

enum PreferencesCopy {
    enum Key {
        case settingsTitle, terminalCategory, appearanceCategory, windowCategory
        case terminalTitle, terminalSubtitle, shellSection, shellSectionHelp, workingDirectory
        case textSection, textSectionHelp, font, fontSize, historySection, historySectionHelp, scrollback, lines
        case appearanceTitle, appearanceSubtitle, themeSection, themeSectionHelp, theme
        case themeKurotty, themeLightty, themeCustom, customColors, customColorsHelp
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
            .terminalTitle: "Terminal", .terminalSubtitle: "Configure new shell sessions, text, and history.",
            .shellSection: "Shell", .shellSectionHelp: "The working directory is used for new terminal sessions.", .workingDirectory: "Working directory",
            .textSection: "Text", .textSectionHelp: "Font changes apply to open terminal surfaces.", .font: "Font", .fontSize: "Font size",
            .historySection: "History", .historySectionHelp: "Limit retained scrollback to keep memory use predictable.", .scrollback: "Scrollback", .lines: "lines",
            .appearanceTitle: "Appearance", .appearanceSubtitle: "Choose a built-in theme or create your own palette.",
            .themeSection: "Terminal theme", .themeSectionHelp: "The sample shows how foreground, ANSI colors, background, and cursor work together.", .theme: "Theme",
            .themeKurotty: "Kurotty", .themeLightty: "Lightty", .themeCustom: "Custom",
            .customColors: "Custom colors", .customColorsHelp: "Changing any color keeps the full palette as a custom theme.",
            .foreground: "Text", .background: "Background", .cursor: "Cursor", .ansiPalette: "ANSI palette · normal and bright",
            .windowTitle: "Window", .windowSubtitle: "Set the default size for new windows.",
            .windowSizeSection: "Default window size", .windowSizeHelp: "Existing windows keep their current size.", .width: "Width", .height: "Height",
            .loaded: "Settings loaded. Changes save automatically.", .loadFailed: "Could not load settings: %@", .saving: "Saving changes…", .saved: "All changes saved.", .saveFailed: "Could not save settings: %@",
        ],
        .korean: [
            .settingsTitle: "설정", .terminalCategory: "터미널", .appearanceCategory: "모양", .windowCategory: "윈도우",
            .terminalTitle: "터미널", .terminalSubtitle: "새 셸 세션과 글꼴, 기록을 설정합니다.",
            .shellSection: "셸", .shellSectionHelp: "새 터미널 세션을 시작할 작업 폴더입니다.", .workingDirectory: "작업 폴더",
            .textSection: "텍스트", .textSectionHelp: "글꼴 변경은 열려 있는 터미널에도 적용됩니다.", .font: "글꼴", .fontSize: "글꼴 크기",
            .historySection: "기록", .historySectionHelp: "메모리 사용량을 예측할 수 있도록 스크롤백 보관량을 제한합니다.", .scrollback: "스크롤백", .lines: "줄",
            .appearanceTitle: "모양", .appearanceSubtitle: "기본 테마를 선택하거나 직접 색상 팔레트를 만들 수 있습니다.",
            .themeSection: "터미널 테마", .themeSectionHelp: "미리보기에서 글자, ANSI 색상, 배경과 커서가 어떻게 적용되는지 확인할 수 있습니다.", .theme: "테마",
            .themeKurotty: "Kurotty", .themeLightty: "Lightty", .themeCustom: "커스텀",
            .customColors: "커스텀 색상", .customColorsHelp: "색상을 하나라도 변경하면 전체 팔레트를 커스텀 테마로 보관합니다.",
            .foreground: "글자", .background: "배경", .cursor: "커서", .ansiPalette: "ANSI 팔레트 · 기본 및 밝은 색",
            .windowTitle: "윈도우", .windowSubtitle: "새 윈도우의 기본 크기를 설정합니다.",
            .windowSizeSection: "기본 윈도우 크기", .windowSizeHelp: "이미 열린 윈도우의 크기는 유지됩니다.", .width: "너비", .height: "높이",
            .loaded: "설정을 불러왔습니다. 변경 사항은 자동으로 저장됩니다.", .loadFailed: "설정을 불러올 수 없습니다: %@", .saving: "변경 사항 저장 중…", .saved: "모든 변경 사항을 저장했습니다.", .saveFailed: "설정을 저장할 수 없습니다: %@",
        ],
        .japanese: [
            .settingsTitle: "設定", .terminalCategory: "ターミナル", .appearanceCategory: "外観", .windowCategory: "ウインドウ",
            .terminalTitle: "ターミナル", .terminalSubtitle: "新しいシェルセッション、テキスト、履歴を設定します。",
            .shellSection: "シェル", .shellSectionHelp: "新しいターミナルセッションで使用する作業フォルダです。", .workingDirectory: "作業フォルダ",
            .textSection: "テキスト", .textSectionHelp: "フォントの変更は開いているターミナルにも適用されます。", .font: "フォント", .fontSize: "フォントサイズ",
            .historySection: "履歴", .historySectionHelp: "メモリ使用量を予測可能にするため、スクロールバックの保持量を制限します。", .scrollback: "スクロールバック", .lines: "行",
            .appearanceTitle: "外観", .appearanceSubtitle: "組み込みテーマを選ぶか、独自のカラーパレットを作成できます。",
            .themeSection: "ターミナルテーマ", .themeSectionHelp: "プレビューで文字、ANSIカラー、背景、カーソルの適用を確認できます。", .theme: "テーマ",
            .themeKurotty: "Kurotty", .themeLightty: "Lightty", .themeCustom: "カスタム",
            .customColors: "カスタムカラー", .customColorsHelp: "いずれかの色を変更すると、パレット全体をカスタムテーマとして保持します。",
            .foreground: "文字", .background: "背景", .cursor: "カーソル", .ansiPalette: "ANSIパレット・標準と明色",
            .windowTitle: "ウインドウ", .windowSubtitle: "新しいウインドウのデフォルトサイズを設定します。",
            .windowSizeSection: "デフォルトサイズ", .windowSizeHelp: "開いているウインドウのサイズは変わりません。", .width: "幅", .height: "高さ",
            .loaded: "設定を読み込みました。変更は自動的に保存されます。", .loadFailed: "設定を読み込めません: %@", .saving: "変更を保存中…", .saved: "すべての変更を保存しました。", .saveFailed: "設定を保存できません: %@",
        ],
    ]
}
