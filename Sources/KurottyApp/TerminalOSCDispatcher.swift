struct TerminalOSCDispatcher {
    enum Event: Equatable {
        case ignored
        case desktopNotification(TerminalNotificationPayload.Content)
        case shellIntegration(TerminalShellIntegration.Event)
        case osc52(TerminalOSC52Policy.Evaluation, base64Payload: String)
    }

    var shellIntegration: TerminalShellIntegration
    private let osc52Policy: TerminalOSC52Policy

    init(
        osc52Policy: TerminalOSC52Policy,
        shellIntegration: TerminalShellIntegration = TerminalShellIntegration()
    ) {
        self.osc52Policy = osc52Policy
        self.shellIntegration = shellIntegration
    }

    @discardableResult
    mutating func dispatch(
        _ command: String,
        origin: TerminalSecurityPolicy.Origin
    ) -> Event {
        let parts = command.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let commandNumber = parts.first else {
            return .ignored
        }

        switch commandNumber {
        case "9":
            guard parts.count == 2,
                  let payload = TerminalNotificationPayload.contentFromOSC9Payload(String(parts[1])) else {
                return .ignored
            }
            return .desktopNotification(payload)
        case "52":
            return dispatchOSC52(parts.count == 2 ? String(parts[1]) : "", origin: origin)
        case "7", "133":
            guard let event = shellIntegration.consumeOsc(command) else {
                return .ignored
            }
            return .shellIntegration(event)
        case "777":
            guard parts.count == 2,
                  let payload = TerminalNotificationPayload.contentFromOSC777Payload(String(parts[1])) else {
                return .ignored
            }
            return .desktopNotification(payload)
        case "1337":
            guard parts.count == 2,
                  let payload = TerminalNotificationPayload.contentFromOSC1337Payload(String(parts[1])) else {
                return .ignored
            }
            return .desktopNotification(payload)
        default:
            return .ignored
        }
    }

    private func dispatchOSC52(
        _ payload: String,
        origin: TerminalSecurityPolicy.Origin
    ) -> Event {
        let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .ignored
        }

        return .osc52(
            osc52Policy.evaluate(
                selection: String(parts[0]),
                payload: String(parts[1]),
                origin: origin
            ),
            base64Payload: String(parts[1])
        )
    }
}
