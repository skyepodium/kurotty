import AppKit

final class TerminalPaneView: NSView {
    private let terminalSurfaceView = TerminalSurfaceView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        configureLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureLayout() {
        terminalSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalSurfaceView)
        NSLayoutConstraint.activate([
            terminalSurfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalSurfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalSurfaceView.topAnchor.constraint(equalTo: topAnchor),
            terminalSurfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(terminalSurfaceView)
    }
}
