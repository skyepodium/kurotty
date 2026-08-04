import AppKit

/// Pane-header indicator for agent activity: a colored dot, plus a rotating arc
/// while the agent is working.
///
/// Rendering contract: everything is CALayer state. The spinner is a single
/// `CABasicAnimation` on a pre-built arc path, so Core Animation produces the
/// frames and no Swift code, allocation, or `draw(_:)` runs per frame. This
/// matters because the view lives in chrome that is laid out while the user is
/// typing. Paths are rebuilt only when the view's size changes.
///
/// Integration: either add it to a header directly, or call
/// `attach(to:leadingAnchor:)` to pin it inside an existing header view.
final class AgentActivityIndicatorView: NSView {
    private let dotLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private var lastPathSize = CGSize.zero
    private var isSpinning = false

    private enum Animation {
        static let rotationKey = "dev.kurotty.agentActivity.spin"
        static let rotationKeyPath = "transform.rotation.z"
    }

    private(set) var status: AgentActivityStatus?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: DesignTokens.Component.agentActivityIndicatorSizePX,
            height: DesignTokens.Component.agentActivityIndicatorSizePX
        )
    }

    override var isFlipped: Bool {
        true
    }

    /// Pins the indicator inside `headerView`, vertically centered, at
    /// `leadingAnchor` plus `leadingInsetPX`. Returns the created constraints so
    /// a caller can deactivate them on teardown.
    @discardableResult
    func attach(
        to headerView: NSView,
        leadingAnchor: NSLayoutXAxisAnchor,
        leadingInsetPX: CGFloat = 0
    ) -> [NSLayoutConstraint] {
        translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(self)
        let constraints = [
            self.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInsetPX),
            centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            widthAnchor.constraint(equalToConstant: DesignTokens.Component.agentActivityIndicatorSizePX),
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.agentActivityIndicatorSizePX),
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }

    /// Applies a resolved status. Pass `nil` to render nothing; the view hides
    /// itself and stops the spinner so it costs nothing while idle.
    func update(status: AgentActivityStatus?) {
        self.status = status
        applyAppearance()
    }

    override func layout() {
        super.layout()
        rebuildPathsIfNeeded()
    }

    private func configureLayers() {
        wantsLayer = true
        layer?.masksToBounds = false
        dotLayer.fillColor = NSColor.clear.cgColor
        dotLayer.strokeColor = nil
        dotLayer.actions = ["path": NSNull(), "fillColor": NSNull(), "hidden": NSNull()]
        arcLayer.fillColor = nil
        arcLayer.lineWidth = DesignTokens.Component.agentActivityIndicatorRingWidthPX
        arcLayer.lineCap = .round
        arcLayer.actions = ["path": NSNull(), "strokeColor": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(arcLayer)
        layer?.addSublayer(dotLayer)
        isHidden = true
    }

    private func rebuildPathsIfNeeded() {
        let size = bounds.size
        guard size != lastPathSize, size.width > 0, size.height > 0 else {
            return
        }
        lastPathSize = size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        let dotRadius = DesignTokens.Component.agentActivityIndicatorDotSizePX / 2
        let dotPath = CGMutablePath()
        dotPath.addArc(center: center, radius: dotRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        dotLayer.path = dotPath
        dotLayer.frame = bounds

        let ringInset = DesignTokens.Component.agentActivityIndicatorRingWidthPX / 2
        let ringRadius = max(min(size.width, size.height) / 2 - ringInset, dotRadius + ringInset)
        let arcPath = CGMutablePath()
        arcPath.addArc(
            center: center,
            radius: ringRadius,
            startAngle: 0,
            endAngle: .pi * 2 * DesignTokens.Component.agentActivityIndicatorArcRatio,
            clockwise: false
        )
        arcLayer.path = arcPath
        arcLayer.frame = bounds
        // Rotation must happen about the arc's own center.
        arcLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        arcLayer.position = center
        arcLayer.bounds = CGRect(origin: .zero, size: size)
    }

    private func applyAppearance() {
        guard let status else {
            isHidden = true
            stopSpinning()
            return
        }
        isHidden = false
        let color = Self.color(for: status.state)
        dotLayer.fillColor = color.cgColor
        arcLayer.strokeColor = color.withAlphaComponent(0.85).cgColor
        toolTip = Self.tooltip(for: status)
        guard status.state == .working else {
            arcLayer.isHidden = true
            stopSpinning()
            return
        }
        arcLayer.isHidden = false
        startSpinning()
    }

    private func startSpinning() {
        guard !isSpinning else {
            return
        }
        isSpinning = true
        let rotation = CABasicAnimation(keyPath: Animation.rotationKeyPath)
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = DesignTokens.Component.agentActivityIndicatorSpinSeconds
        rotation.repeatCount = .greatestFiniteMagnitude
        rotation.isRemovedOnCompletion = false
        arcLayer.add(rotation, forKey: Animation.rotationKey)
    }

    private func stopSpinning() {
        guard isSpinning else {
            return
        }
        isSpinning = false
        arcLayer.removeAnimation(forKey: Animation.rotationKey)
        arcLayer.isHidden = true
    }

    static func color(for state: AgentActivityState) -> NSColor {
        switch state {
        case .working:
            return DesignTokens.Color.accentBlue
        case .waitingForInput:
            return DesignTokens.Color.warningOrange
        case .blocked:
            return DesignTokens.Color.errorRed
        case .done:
            return DesignTokens.Color.successGreen
        }
    }

    static func tooltip(
        for status: AgentActivityStatus,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        let stateLabel: String
        switch status.state {
        case .working:
            stateLabel = AppLocalization.string(.agentStatusWorking, language: language)
        case .waitingForInput:
            stateLabel = AppLocalization.string(.agentStatusWaitingForInput, language: language)
        case .blocked:
            stateLabel = AppLocalization.string(.agentStatusBlocked, language: language)
        case .done:
            stateLabel = AppLocalization.string(.agentStatusDone, language: language)
        }
        let agent = status.agentName.map { "\($0): " } ?? ""
        guard let detail = status.detail else {
            return agent + stateLabel
        }
        return agent + stateLabel + " — " + detail
    }
}
