import AppKit
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class TerminalNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TerminalNotifier()

    private let supportsUserNotifications = Bundle.main.bundleURL.pathExtension == "app"
    private lazy var center: UNUserNotificationCenter? = {
        guard supportsUserNotifications else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()
    private var didRequestAuthorization = false

    private override init() {
        super.init()
    }

    func requestAuthorization() {
        guard !didRequestAuthorization, let center else { return }
        didRequestAuthorization = true
        center.getNotificationSettings { settings in
            NSLog(
                "Kurotty notification settings before request: authorization=%ld alert=%ld sound=%ld",
                settings.authorizationStatus.rawValue,
                settings.alertSetting.rawValue,
                settings.soundSetting.rawValue
            )
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Kurotty notification authorization failed: %@", error.localizedDescription)
                return
            }
            NSLog("Kurotty notification authorization granted: %@", granted ? "yes" : "no")
            center.getNotificationSettings { settings in
                NSLog(
                    "Kurotty notification settings after request: authorization=%ld alert=%ld sound=%ld",
                    settings.authorizationStatus.rawValue,
                    settings.alertSetting.rawValue,
                    settings.soundSetting.rawValue
                )
            }
        }
    }

    func notifyShellDidExit(status: Int32) {
        let body: String
        if status == 0 {
            body = AppConstants.Notifications.shellExitSuccessBody
        } else {
            body = "\(AppConstants.Notifications.shellExitFailureBodyPrefix) \(status)."
        }
        deliver(
            title: AppConstants.Notifications.shellExitTitle,
            body: body,
            identifierPrefix: AppConstants.Notifications.shellExitIdentifierPrefix
        )
    }

    func notifyItermOsc9(message: String) {
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        deliver(
            title: AppConstants.Notifications.defaultTitle,
            body: body,
            identifierPrefix: AppConstants.Notifications.osc9IdentifierPrefix
        )
    }

    func notifyCodexTaskCompleted(sessionTitle: String, promptSummary: String?) {
        let trimmedPrompt = promptSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if let trimmedPrompt, !trimmedPrompt.isEmpty {
            body = "Session \(sessionTitle): \(trimmedPrompt)"
        } else {
            body = "Session \(sessionTitle): \(AppConstants.Notifications.codexTaskCompletedBody)"
        }
        deliver(
            title: AppConstants.Notifications.defaultTitle,
            body: body,
            identifierPrefix: AppConstants.Notifications.codexIdentifierPrefix
        )
    }

    func notifyTestNotification() {
        deliver(
            title: AppConstants.Notifications.defaultTitle,
            body: AppConstants.Notifications.testBody,
            identifierPrefix: "\(AppConstants.Notifications.categoryIdentifier).test"
        )
    }

    private func deliver(title: String, body: String, identifierPrefix: String) {
        guard let center else {
            NSLog("Kurotty notification skipped outside app bundle: title=%@ body=%@", title, body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = AppConstants.Notifications.categoryIdentifier
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        NSLog("Kurotty notification enqueue: identifier=%@ title=%@ body=%@", request.identifier, title, body)
        center.add(request) { error in
            if let error {
                NSLog("Kurotty notification failed: %@", error.localizedDescription)
            } else {
                NSLog("Kurotty notification delivered request: %@", request.identifier)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Kurotty task notifications should surface even while the terminal window is focused.
        completionHandler([.banner, .list, .sound])
    }
}
