import Foundation

/// Thin forward from agent activity state to its status-bar label.
///
/// The bar's copy now lives in `AppLocalization` (translated strings) and
/// `AppConstants.StatusBar` (universal symbols and unit abbreviations); its
/// geometry lives in `DesignTokens.Component.StatusBar`. What is left here is
/// the one thing none of those own: the mapping from a domain state to the key
/// that names it.
enum TerminalStatusBarStrings {
    static func stateLabel(
        for state: AgentActivityState,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        switch state {
        case .working:
            return AppLocalization.string(.statusBarAgentWorking, language: language)
        case .waitingForInput:
            return AppLocalization.string(.statusBarAgentNeedsInput, language: language)
        case .blocked:
            return AppLocalization.string(.statusBarAgentBlocked, language: language)
        case .done:
            return AppLocalization.string(.statusBarAgentIdle, language: language)
        }
    }
}
