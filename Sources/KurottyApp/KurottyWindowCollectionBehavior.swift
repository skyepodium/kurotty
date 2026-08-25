import AppKit

enum KurottyWindowCollectionBehavior {
    static let splitViewBehavior: NSWindow.CollectionBehavior = [
        .fullScreenPrimary,
        .managed,
    ]

    @MainActor
    static func apply(to window: NSWindow?) {
        guard let window else {
            return
        }
        window.collectionBehavior.formUnion(splitViewBehavior)
    }
}
