@MainActor
public protocol TerminalFrameRenderer: AnyObject {
    var onPresented: (() -> Void)? { get set }

    func update(frame: TerminalFrame)
}
