struct TerminalOSCDispatcher {
    enum Event: Equatable {
        case ignored
        case desktopNotification(TerminalNotificationPayload.Content)
        case shellIntegration(TerminalShellIntegration.Event)
        /// An OSC 9;4 progress report. Progress data, never a desktop message:
        /// the numeric OSC 9 extensions were already kept out of the
        /// notification path, and this is where they now go instead.
        case commandProgress(TerminalCommandProgressReport)
        case osc52(TerminalOSC52Policy.Evaluation, base64Payload: String)
        case kittyClipboard(TerminalKittyClipboardController.Event)
        case kittyDragAndDrop(TerminalKittyDragAndDropController.Event)
        /// A picture the program asked the terminal to draw where the cursor is.
        case inlineImage(TerminalInlineImagePayload)
    }

    var shellIntegration: TerminalShellIntegration
    var kittyClipboard: TerminalKittyClipboardController
    var kittyDragAndDrop: TerminalKittyDragAndDropController
    private let osc52Policy: TerminalOSC52Policy

    init(
        osc52Policy: TerminalOSC52Policy,
        shellIntegration: TerminalShellIntegration = TerminalShellIntegration(),
        kittyClipboard: TerminalKittyClipboardController = TerminalKittyClipboardController(),
        kittyDragAndDrop: TerminalKittyDragAndDropController = TerminalKittyDragAndDropController()
    ) {
        self.osc52Policy = osc52Policy
        self.shellIntegration = shellIntegration
        self.kittyClipboard = kittyClipboard
        self.kittyDragAndDrop = kittyDragAndDrop
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
            guard parts.count == 2 else {
                return .ignored
            }
            // Progress is tried first: `9;4;…` is a numeric extension the
            // notification parser deliberately refuses, so asking it first would
            // only ever return `nil` here.
            if let report = TerminalCommandProgressReport.parse(oscPayload: String(parts[1])) {
                return .commandProgress(report)
            }
            guard let payload = TerminalNotificationPayload.contentFromOSC9Payload(String(parts[1])) else {
                return .ignored
            }
            return .desktopNotification(payload)
        case "52":
            return dispatchOSC52(parts.count == 2 ? String(parts[1]) : "", origin: origin)
        case "72":
            guard parts.count == 2 else {
                return .ignored
            }
            return .kittyDragAndDrop(kittyDragAndDrop.dispatch(String(parts[1])))
        case "99":
            guard parts.count == 2,
                  let payload = TerminalNotificationPayload.contentFromOSC99Payload(String(parts[1])) else {
                return .ignored
            }
            return .desktopNotification(payload)
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
            guard parts.count == 2 else {
                return .ignored
            }
            // The same sequence carries iTerm2's notifications and its inline
            // images. The image form is checked first because it is the one
            // with a shape — `File=…:<base64>` — and a notification payload
            // cannot be mistaken for it.
            if let image = TerminalInlineImagePayload.parse(String(parts[1])) {
                return .inlineImage(image)
            }
            guard let payload = TerminalNotificationPayload.contentFromOSC1337Payload(String(parts[1])) else {
                return .ignored
            }
            return .desktopNotification(payload)
        case "5522":
            guard parts.count == 2 else {
                return .ignored
            }
            return .kittyClipboard(
                kittyClipboard.dispatch(
                    String(parts[1]),
                    policy: osc52Policy.policy,
                    origin: origin
                )
            )
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
