import AppKit

final class SplitTerminalView: NSSplitView {
    init(axis: NSLayoutConstraint.Orientation) {
        super.init(frame: .zero)
        isVertical = axis == .vertical
        dividerStyle = .paneSplitter
        addArrangedSubview(TerminalPaneView())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func split(axis: NSLayoutConstraint.Orientation) {
        isVertical = axis == .vertical
        addArrangedSubview(TerminalPaneView())
        adjustSubviews()
    }
}
