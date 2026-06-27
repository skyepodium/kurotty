import AppKit
import Foundation
import UserNotifications

@MainActor
final class TerminalNotifier {
    static let shared = TerminalNotifier()

    private let supportsUserNotifications = Bundle.main.bundleURL.pathExtension == "app"
    private lazy var center: UNUserNotificationCenter? = {
        guard supportsUserNotifications else { return nil }
        return UNUserNotificationCenter.current()
    }()
    private var didRequestAuthorization = false

    private init() {}

    func requestAuthorization() {
        guard !didRequestAuthorization, let center else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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

    private func deliver(title: String, body: String, identifierPrefix: String) {
        guard !NSApp.isActive, let center else { return }
        requestAuthorization()

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
        center.add(request) { error in
            if let error {
                NSLog("Kurotty notification failed: %@", error.localizedDescription)
            }
        }
    }
}
