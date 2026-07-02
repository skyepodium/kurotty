struct TerminalOSCDispatcher {
    enum Event: Equatable {
        case ignored
        case shellIntegration(TerminalShellIntegration.Event)
        case osc52(TerminalOSC52Policy.Evaluation)
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
        case "52":
            return dispatchOSC52(parts.count == 2 ? String(parts[1]) : "", origin: origin)
        case "7", "133":
            guard let event = shellIntegration.consumeOsc(command) else {
                return .ignored
            }
            return .shellIntegration(event)
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
            )
        )
    }
}
