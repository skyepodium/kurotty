import AppKit

/// Window-content root view that accepts a dragged terminal pane and hands it
/// to the window's drag coordinator. Extracted from
/// `TerminalWindowController.swift`; the controller wires `onPaneDrop` and
/// `onPaneCanDrop` during window setup.
@MainActor
final class TerminalPaneDropTargetView: NSView {
    var onPaneDrop: (() -> Bool)?
    var onPaneCanDrop: (() -> Bool)?
    var chromeTheme = DesignTokens.ChromeTheme.dark {
        didSet { updateDropAppearance() }
    }

    private var isDropHighlighted = false {
        didSet {
            updateDropAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([TerminalPaneDragCoordinator.pasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [TerminalPaneDragCoordinator.pasteboardType.rawValue]) else {
            return []
        }
        guard onPaneCanDrop?() == true else {
            return []
        }
        isDropHighlighted = true
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onPaneCanDrop?() == true else {
            isDropHighlighted = false
            return []
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropHighlighted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropHighlighted = false
        return onPaneDrop?() == true
    }

    private func updateDropAppearance() {
        layer?.borderWidth = isDropHighlighted ? DesignTokens.Component.paneDropTargetBorderWidthPX : 0
        layer?.borderColor = isDropHighlighted ? DesignTokens.Color.paneDropTargetBorder.cgColor : nil
        layer?.backgroundColor = isDropHighlighted
            ? DesignTokens.Color.paneDropTargetBackground.cgColor
            : chromeTheme.windowBackground.cgColor
    }
}
