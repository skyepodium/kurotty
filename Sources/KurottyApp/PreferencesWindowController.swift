import AppKit

final class PreferencesWindowController: NSWindowController {
    init() {
        let view = PreferencesView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kurotty Preferences"
        window.contentView = view
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class PreferencesView: NSView {
    private let fontSize = NSSlider(value: 13, minValue: 9, maxValue: 24, target: nil, action: nil)
    private let scrollback = NSTextField(string: "1000000")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label("Font size"))
        stack.addArrangedSubview(fontSize)
        stack.addArrangedSubview(label("Scrollback lines"))
        stack.addArrangedSubview(scrollback)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            fontSize.widthAnchor.constraint(equalToConstant: 240),
            scrollback.widthAnchor.constraint(equalToConstant: 160),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        return field
    }
}
