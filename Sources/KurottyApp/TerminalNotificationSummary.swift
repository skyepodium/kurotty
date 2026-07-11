import Foundation

enum TerminalSubmittedCommandSummary {
    static func notificationBody(from submittedInputText: String) -> String? {
        let summary = submittedInputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !summary.isEmpty else {
            return nil
        }
        guard summary.count > AppConstants.Notifications.commandSummaryMaxCharacters else {
            return summary
        }
        return String(summary.prefix(AppConstants.Notifications.commandSummaryMaxCharacters))
    }
}

enum TerminalNotificationPayload {
    enum Source: Equatable {
        case osc9
        case osc777
        case osc1337
    }

    struct Content: Equatable {
        let source: Source
        let title: String
        let subtitle: String
        let body: String

        func addingFallbackSubtitle(_ fallback: String) -> Content {
            guard subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let normalizedFallback = TerminalNotificationPayload.body(fromExplicitPayload: fallback) else {
                return self
            }
            return Content(source: source, title: title, subtitle: normalizedFallback, body: body)
        }
    }

    static func body(fromExplicitPayload payload: String) -> String? {
        let body = stripTerminalControls(from: payload)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return nil
        }
        guard body.count > AppConstants.Notifications.terminalNotificationMaxCharacters else {
            return body
        }
        return String(body.prefix(AppConstants.Notifications.terminalNotificationMaxCharacters))
    }

    static func contentFromOSC9Payload(_ payload: String) -> Content? {
        let firstParameter = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
        if payload.contains(";"), firstParameter.flatMap({ Int($0) }) != nil {
            return nil
        }
        guard let body = body(fromExplicitPayload: payload) else {
            return nil
        }
        return Content(
            source: .osc9,
            title: AppConstants.Notifications.terminalAlertTitle,
            subtitle: "",
            body: body
        )
    }

    static func contentFromOSC777Payload(_ payload: String) -> Content? {
        let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "notify" else {
            return nil
        }
        let title = body(fromExplicitPayload: String(parts[1]))
            ?? AppConstants.Notifications.terminalNotificationTitle
        let body = body(fromExplicitPayload: String(parts[2])) ?? title
        return Content(source: .osc777, title: title, subtitle: "", body: body)
    }

    static func contentFromOSC1337Payload(_ payload: String) -> Content? {
        let notificationPrefix = "Notification="
        guard payload.hasPrefix(notificationPrefix) else {
            return nil
        }
        let encodedFields = payload.dropFirst(notificationPrefix.count)
        var fields: [String: String] = [:]
        for field in encodedFields.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let data = Data(base64Encoded: String(pair[1])),
                  let value = String(data: data, encoding: .utf8) else {
                continue
            }
            fields[String(pair[0])] = value
        }
        guard let body = fields["message"].flatMap(body(fromExplicitPayload:)) else {
            return nil
        }
        let title = fields["title"].flatMap(body(fromExplicitPayload:))
            ?? AppConstants.Notifications.terminalAlertTitle
        let subtitle = fields["subtitle"].flatMap(body(fromExplicitPayload:)) ?? ""
        return Content(source: .osc1337, title: title, subtitle: subtitle, body: body)
    }

    private static func stripTerminalControls(from text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                result.unicodeScalars.append(scalar)
                continue
            }
            if scalar.value < 0x20 || scalar.value == 0x7F {
                continue
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

struct TerminalCommandCompletionNotificationContent: Equatable {
    let title: String
    let subtitle: String
    let body: String
    let exitCode: Int?
    let duration: TimeInterval?
    let cwd: String?

    static func make(from context: TerminalCommandCompletionContext) -> TerminalCommandCompletionNotificationContent {
        let exitCode = context.exitCode
        let title = exitCode.map {
            $0 == 0 ? AppConstants.Notifications.commandFinishedTitle : AppConstants.Notifications.commandFailedTitle
        } ?? AppConstants.Notifications.commandFinishedTitle
        var bodyLines = [exitCode.map { "Exit code: \($0)" } ?? "Exit code: unknown"]
        if let duration = context.duration {
            bodyLines.append("Duration: \(formattedDuration(duration))")
        }
        if let cwd = context.cwd {
            bodyLines.append("Directory: \(cwd)")
        }

        return TerminalCommandCompletionNotificationContent(
            title: title,
            subtitle: context.commandText ?? "",
            body: bodyLines.joined(separator: "\n"),
            exitCode: exitCode,
            duration: context.duration,
            cwd: context.cwd
        )
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", max(0, duration))
    }
}
