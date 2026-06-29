import Foundation
import Sparkle

@MainActor
final class UpdateController {
    private enum ConfigurationState {
        case unavailable
        case debug
        case configured
    }

    private let state: ConfigurationState

    private var updaterController: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        state = Self.currentState(bundle: bundle)
        if state == .configured {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
    }

    var canCheckForUpdates: Bool {
        state != .unavailable
    }

    var isFullyConfigured: Bool {
        state == .configured
    }

    var isDebugMode: Bool {
        state == .debug
    }

    func checkForUpdates(_ sender: Any?) {
        guard updaterController != nil else {
            return
        }
        updaterController?.checkForUpdates(sender)
    }

    static func isConfigured(bundle: Bundle = .main) -> Bool {
        guard let publicKey = bundle.object(forInfoDictionaryKey: AppConstants.Bundle.sparklePublicKeyInfoKey) as? String else {
            return false
        }
        return !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isDebugModeEnabled(bundle: Bundle = .main) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let argumentEnabled = ProcessInfo.processInfo.arguments.contains(
            AppConstants.Bundle.sparkleDebugUpdatesArgument
        )
        let envEnabled = environment[AppConstants.Bundle.sparkleDebugUpdatesEnvironmentName] == "1" ||
            environment[AppConstants.Bundle.sparkleDebugUpdatesEnvironmentName]?.lowercased() == "true"
        return argumentEnabled || envEnabled
    }

    private static func currentState(bundle: Bundle = .main) -> ConfigurationState {
        if isConfigured(bundle: bundle) {
            return .configured
        }
        if isDebugModeEnabled(bundle: bundle) {
            return .debug
        }
        return .unavailable
    }

}
