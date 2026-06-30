import AppKit
import Foundation
import os
@preconcurrency import UserNotifications

private let terminalNotificationLogger = Logger(subsystem: "dev.kurotty.app", category: "notifications")

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
            terminalNotificationLogger.info("settings before request authorization=\(settings.authorizationStatus.rawValue, privacy: .public) alert=\(settings.alertSetting.rawValue, privacy: .public) sound=\(settings.soundSetting.rawValue, privacy: .public)")
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                terminalNotificationLogger.error("authorization failed error=\(error.localizedDescription, privacy: .public)")
                return
            }
            terminalNotificationLogger.info("authorization granted=\(granted ? "yes" : "no", privacy: .public)")
            center.getNotificationSettings { settings in
                terminalNotificationLogger.info("settings after request authorization=\(settings.authorizationStatus.rawValue, privacy: .public) alert=\(settings.alertSetting.rawValue, privacy: .public) sound=\(settings.soundSetting.rawValue, privacy: .public)")
            }
        }
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

    func notifyBackgroundTaskCompleted(body: String) {
        deliver(
            title: AppConstants.Notifications.defaultTitle,
            body: body,
            identifierPrefix: AppConstants.Notifications.backgroundTaskIdentifierPrefix
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
        let metadata = TerminalNotificationLogMetadata(identifierPrefix: identifierPrefix, title: title, body: body)
        guard let center else {
            terminalNotificationLogger.info("skipped outside app bundle metadata=\(metadata.description, privacy: .public)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = AppConstants.Notifications.categoryIdentifier
        content.sound = .default
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .active
        }

        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        terminalNotificationLogger.info("enqueue identifier=\(request.identifier, privacy: .public) metadata=\(metadata.description, privacy: .public)")
        center.add(request) { error in
            if let error {
                terminalNotificationLogger.error("delivery failed error=\(error.localizedDescription, privacy: .public)")
            } else {
                terminalNotificationLogger.info("delivered request identifier=\(request.identifier, privacy: .public)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        terminalNotificationLogger.info("will present identifier=\(notification.request.identifier, privacy: .public)")
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        terminalNotificationLogger.info("notification response identifier=\(response.notification.request.identifier, privacy: .public)")
        Task { @MainActor in
            (NSApp.delegate as? AppDelegate)?.focusExistingTerminalWindow()
        }
        completionHandler()
    }
}
