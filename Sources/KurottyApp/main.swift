import AppKit

if KurottyNotificationBridgeCommandLine.handleIfNeeded(arguments: ProcessInfo.processInfo.arguments) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
