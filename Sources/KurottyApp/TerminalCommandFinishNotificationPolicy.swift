import Foundation
import KurottyCore

/// Which command completions may raise a banner.
///
/// Stored as a raw string in the settings file, like `terminal.theme`: a
/// hand-edited value that no case matches must land on the default instead of
/// failing the whole document.
enum TerminalCommandFinishNotificationMode: String, CaseIterable, Equatable {
    /// No command completion notifies, whatever the pane's focus.
    case off
    /// Only panes the user is not looking at notify.
    case unfocused
    /// Every completion notifies, including in the focused pane.
    case always

    static let `default` = TerminalCommandFinishNotificationMode(
        rawValue: SettingsDefaults.notifyOnCommandFinish
    ) ?? .unfocused

    /// Trims and lowercases before matching so a file written by hand
    /// (`"Unfocused"`, `" always "`) still expresses what its author meant.
    static func parse(_ rawValue: String) -> TerminalCommandFinishNotificationMode? {
        TerminalCommandFinishNotificationMode(
            rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}

/// Decides whether one finished command is worth interrupting the user for.
///
/// Every unfocused pane finishing any command used to fire a banner, so a
/// background `ls` while the user was in another app was indistinguishable from
/// a twenty-minute build. Users mute the app, which silences OSC 9/777/1337
/// alongside it, so the filter has to live below the notifier rather than in the
/// user's Notification Center settings.
///
/// Deliberately a free function on a value type: the caller is a view that
/// cannot be instantiated in a unit test, and this decision is the part worth
/// testing.
enum TerminalCommandFinishNotificationPolicy {
    /// - Parameter actualDuration: what OSC 133;D reported, or `nil` when the
    ///   shell integration never timed the command. Unknown counts as short:
    ///   without a duration there is no evidence the user walked away, and a
    ///   false banner costs more than a missed one.
    static func shouldNotify(
        mode: TerminalCommandFinishNotificationMode,
        minimumDuration: TimeInterval,
        actualDuration: TimeInterval?,
        isFocused: Bool
    ) -> Bool {
        switch mode {
        case .off:
            return false
        case .unfocused:
            guard !isFocused else { return false }
        case .always:
            break
        }

        guard let actualDuration else {
            // A zero threshold means "every command", which a missing duration
            // must not veto.
            return minimumDuration <= 0
        }
        return actualDuration >= minimumDuration
    }
}
