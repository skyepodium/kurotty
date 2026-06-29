import AppKit

@MainActor
final class TerminalPaneDragCoordinator: NSObject, NSDraggingSource {
    static let shared = TerminalPaneDragCoordinator()
    static let pasteboardType = NSPasteboard.PasteboardType("dev.kurotty.terminal-pane")

    private struct DragContext {
        weak var pane: TerminalPaneView?
        weak var sourceSplitView: SplitTerminalView?
        weak var sourceController: TerminalWindowController?
    }

    private var dragContext: DragContext?
    private var detachedWindowControllers: [TerminalWindowController] = []

    private override init() {
        super.init()
    }

    func beginDraggingPane(_ pane: TerminalPaneView, from sourceSplitView: SplitTerminalView, with event: NSEvent) {
        guard let sourceController = pane.window?.windowController as? TerminalWindowController else {
            return
        }
        dragContext = DragContext(
            pane: pane,
            sourceSplitView: sourceSplitView,
            sourceController: sourceController
        )

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(UUID().uuidString, forType: Self.pasteboardType)

        let dragImage = makeDragImage(for: pane)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            NSRect(origin: .zero, size: dragImage.size),
            contents: dragImage
        )
        pane.beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func moveDraggedPaneToTab(in controller: TerminalWindowController) -> Bool {
        guard let context = dragContext,
              context.sourceController !== controller,
              let pane = context.pane,
              let detachedPane = context.sourceController?.detachPaneForDrag(pane)
        else {
            return false
        }
        controller.attachDraggedPaneAsTab(detachedPane)
        dragContext = nil
        return true
    }

    func canMoveDraggedPane(to controller: TerminalWindowController) -> Bool {
        guard let sourceController = dragContext?.sourceController else {
            return false
        }
        return sourceController !== controller
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == [] {
            detachDraggedPaneToNewWindow(at: screenPoint)
        }
        dragContext = nil
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    private func detachDraggedPaneToNewWindow(at screenPoint: NSPoint) {
        guard let context = dragContext,
              let pane = context.pane,
              let detachedPane = context.sourceController?.detachPaneForDrag(pane)
        else {
            return
        }
        let controller = TerminalWindowController(detachedPane: detachedPane)
        controller.showWindow(nil)
        position(controller.window, near: screenPoint)
        retainDetachedWindowController(controller)
    }

    private func makeDragImage(for pane: TerminalPaneView) -> NSImage {
        let imageSize = NSSize(width: min(max(pane.bounds.width, 220), 420), height: DesignTokens.Component.terminalPaneChromeHeightPX)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: imageSize)
        DesignTokens.Color.paneHeaderBackground.setFill()
        rect.fill()
        DesignTokens.Color.paneDropTargetBorder.setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: DesignTokens.Typography.paneHeaderFontSizePT, weight: .semibold),
            .foregroundColor: DesignTokens.Color.textPrimary,
        ]
        pane.displayTitle.draw(
            in: rect.insetBy(dx: 12, dy: 8),
            withAttributes: attributes
        )
        image.unlockFocus()
        return image
    }

    private func position(_ window: NSWindow?, near screenPoint: NSPoint) {
        guard let window else {
            return
        }
        let frame = window.frame
        let origin = NSPoint(
            x: screenPoint.x - frame.width / 2,
            y: screenPoint.y - DesignTokens.Component.terminalPaneChromeHeightPX
        )
        window.setFrameOrigin(origin)
    }

    private func retainDetachedWindowController(_ controller: TerminalWindowController) {
        detachedWindowControllers.append(controller)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(detachedWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: controller.window,
        )
    }

    @objc private func detachedWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        detachedWindowControllers.removeAll { $0.window === window }
    }
}
