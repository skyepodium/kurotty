import AppKit
import Foundation
import os
@preconcurrency import UserNotifications

private let terminalNotificationLogger = Logger(subsystem: "dev.kurotty.app", category: "notifications")

final class TerminalNotifier: NSObject {
    @MainActor
    static let shared = TerminalNotifier()

    private let notificationDelegate = TerminalNotificationDelegate()
    private let supportsUserNotifications = Bundle.main.bundleURL.pathExtension == "app"
    private lazy var center: UNUserNotificationCenter? = {
        guard supportsUserNotifications else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        return center
    }()
    private var didRequestAuthorization = false

    private override init() {
        super.init()
    }

    @MainActor
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

    @MainActor
    func notifyItermOsc9(message: String) {
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        deliver(
            title: AppConstants.Notifications.defaultTitle,
            body: body,
            identifierPrefix: AppConstants.Notifications.osc9IdentifierPrefix
        )
    }

    @MainActor
    func notifyBackgroundTaskCompleted(body: String) {
        deliver(
            title: AppConstants.Notifications.defaultTitle,
            body: body,
            identifierPrefix: AppConstants.Notifications.backgroundTaskIdentifierPrefix
        )
    }

    @MainActor
    func notifyTestNotification() {
        deliver(
            title: AppConstants.Notifications.defaultTitle,
            body: AppConstants.Notifications.testBody,
            identifierPrefix: "\(AppConstants.Notifications.categoryIdentifier).test"
        )
    }

    @MainActor
    private func deliver(title: String, body: String, identifierPrefix: String) {
        let metadata = TerminalNotificationLogMetadata(identifierPrefix: identifierPrefix, title: title, body: body)
        guard let center else {
            deliverDevelopmentNotification(title: title, body: body, metadata: metadata)
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

    @MainActor
    private func deliverDevelopmentNotification(
        title: String,
        body: String,
        metadata: TerminalNotificationLogMetadata
    ) {
        let script = "display notification \(appleScriptString(body)) with title \(appleScriptString(title))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AppConstants.Notifications.developmentNotificationExecutablePath)
        process.arguments = ["-e", script]
        do {
            try process.run()
            terminalNotificationLogger.info("development fallback enqueue metadata=\(metadata.description, privacy: .public)")
        } catch {
            terminalNotificationLogger.error("development fallback failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

}

private final class TerminalNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
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
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        terminalNotificationLogger.info("notification response identifier=\(response.notification.request.identifier, privacy: .public)")
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        Task { @MainActor in
            (NSApp.delegate as? AppDelegate)?.focusExistingTerminalWindow()
            completionHandler()
        }
    }
}
