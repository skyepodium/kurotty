import AppKit

struct PreferencesValidationStatus: Equatable {
    enum Kind: Equatable {
        case valid
        case warnings
        case errors
    }

    var kind: Kind
    var message: String
    var issues: [AppSettingsValidationIssue]

    var canSave: Bool {
        kind != .errors
    }
}

enum PreferencesValidationPresenter {
    static func status(
        for rawJSON: String,
        language: AppLanguage = .english,
        directoryExists: (String) -> Bool = defaultDirectoryExists
    ) -> PreferencesValidationStatus {
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(rawJSON.utf8))
            let report = AppSettingsValidation.report(for: settings, directoryExists: directoryExists)
            return status(for: report, language: language)
        } catch {
            return PreferencesValidationStatus(
                kind: .errors,
                message: "\(AppLocalization.string(.errors, language: language)): \(String(format: AppLocalization.string(.invalidSettingsJSON, language: language), error.localizedDescription))",
                issues: []
            )
        }
    }

    private static func status(for report: AppSettingsValidationReport, language: AppLanguage) -> PreferencesValidationStatus {
        let errors = report.issues.filter { $0.severity == .error }
        if !errors.isEmpty {
            return PreferencesValidationStatus(
                kind: .errors,
                message: "\(AppLocalization.string(.errors, language: language)): \(summary(for: errors))",
                issues: report.issues
            )
        }

        let warnings = report.issues.filter { $0.severity == .warning }
        if !warnings.isEmpty {
            return PreferencesValidationStatus(
                kind: .warnings,
                message: "\(AppLocalization.string(.warnings, language: language)): \(summary(for: warnings))",
                issues: report.issues
            )
        }

        return PreferencesValidationStatus(
            kind: .valid,
            message: AppLocalization.string(.settingsValid, language: language),
            issues: report.issues
        )
    }

    private static func summary(for issues: [AppSettingsValidationIssue]) -> String {
        issues.map(\.message).joined(separator: " ")
    }

    private static func defaultDirectoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

@MainActor
final class PreferencesWindowController: NSWindowController {
    init() {
        let store = AppSettingsStore.shared
        let view = PreferencesView(frame: NSRect(
            x: 0,
            y: 0,
            width: DesignTokens.Component.preferencesWidthPX,
            height: DesignTokens.Component.preferencesHeightPX
        ), store: store)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let initialContentSize = NSSize(
            width: DesignTokens.Component.preferencesWidthPX,
            height: DesignTokens.Component.preferencesHeightPX
        )
        window.title = AppLocalization.format(.settingsWindow, AppConstants.Bundle.displayName)
        window.contentView = view
        window.setContentSize(initialContentSize)
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refreshLocalization() {
        window?.title = AppLocalization.format(.settingsWindow, AppConstants.Bundle.displayName)
    }
}
