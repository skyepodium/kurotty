import AppKit

/// Native material backing shared by the navigation sidebars.
///
/// The material provides the soft translucency users expect from macOS while
/// the theme-owned wash keeps the result stable across wallpapers and windows.
@MainActor
final class TerminalSidebarGlassBackgroundView: NSVisualEffectView {
    private let tintView = NSView()
    private let tintGradientLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        isEmphasized = false

        tintView.wantsLayer = true
        tintView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        tintView.layer?.addSublayer(tintGradientLayer)
        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView)
        NSLayoutConstraint.activate([
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        appearance = theme.windowAppearance
        let isLight = theme.windowAppearance?.name == .aqua
        tintGradientLayer.colors = isLight
            ? [
                theme.surfaceSidebar.withAlphaComponent(0.88).cgColor,
                NSColor.designTokenSRGB(0xDF_E4_FB, alpha: 0.72).cgColor,
                NSColor.designTokenSRGB(0xF0_E4_F5, alpha: 0.68).cgColor,
              ]
            : [
                theme.surfaceSidebar.withAlphaComponent(0.72).cgColor,
                NSColor.designTokenSRGB(0x24_21_39, alpha: 0.56).cgColor,
                NSColor.designTokenSRGB(0x2B_20_35, alpha: 0.52).cgColor,
              ]
        tintGradientLayer.locations = [0, 0.56, 1]
        tintGradientLayer.startPoint = CGPoint(x: 0.15, y: 1)
        tintGradientLayer.endPoint = CGPoint(x: 0.85, y: 0)
    }

    override func layout() {
        super.layout()
        tintGradientLayer.frame = tintView.bounds
    }
}
