import AppKit
import simd

enum DesignTokens {
    enum Color {
        static let windowBackground = NSColor(calibratedRed: 250.0 / 255.0, green: 250.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
        static let topChromeBackground = NSColor(calibratedRed: 241.0 / 255.0, green: 241.0 / 255.0, blue: 241.0 / 255.0, alpha: 1)
        static let activeTabBackground = NSColor.white
        static let inactiveTabBackground = NSColor(calibratedRed: 233.0 / 255.0, green: 233.0 / 255.0, blue: 233.0 / 255.0, alpha: 1)
        static let inactiveTabHoverBackground = NSColor(calibratedRed: 245.0 / 255.0, green: 245.0 / 255.0, blue: 245.0 / 255.0, alpha: 1)
        static let paneHeaderBackground = NSColor(calibratedRed: 246.0 / 255.0, green: 246.0 / 255.0, blue: 246.0 / 255.0, alpha: 1)
        static let paneHeaderHoverBackground = NSColor(calibratedRed: 251.0 / 255.0, green: 251.0 / 255.0, blue: 251.0 / 255.0, alpha: 1)
        static let inputStatusBackground = NSColor(calibratedRed: 244.0 / 255.0, green: 244.0 / 255.0, blue: 244.0 / 255.0, alpha: 1)
        static let borderHairline = NSColor(calibratedRed: 221.0 / 255.0, green: 221.0 / 255.0, blue: 221.0 / 255.0, alpha: 1)
        static let divider = NSColor(calibratedRed: 224.0 / 255.0, green: 224.0 / 255.0, blue: 224.0 / 255.0, alpha: 1)
        static let textPrimary = NSColor(calibratedRed: 36.0 / 255.0, green: 36.0 / 255.0, blue: 36.0 / 255.0, alpha: 1)
        static let textSecondary = NSColor(calibratedRed: 119.0 / 255.0, green: 119.0 / 255.0, blue: 119.0 / 255.0, alpha: 1)
        static let textMuted = NSColor(calibratedRed: 153.0 / 255.0, green: 153.0 / 255.0, blue: 153.0 / 255.0, alpha: 1)
        static let accentBlue = NSColor(calibratedRed: 91.0 / 255.0, green: 124.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
        static let accentPurple = NSColor(calibratedRed: 139.0 / 255.0, green: 92.0 / 255.0, blue: 246.0 / 255.0, alpha: 1)
        static let successGreen = NSColor(calibratedRed: 47.0 / 255.0, green: 191.0 / 255.0, blue: 113.0 / 255.0, alpha: 1)
        static let warningOrange = NSColor(calibratedRed: 233.0 / 255.0, green: 148.0 / 255.0, blue: 26.0 / 255.0, alpha: 1)
        static let cyanTerminalAccent = NSColor(calibratedRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 1)
        static let scrollerThumb = NSColor(calibratedRed: 207.0 / 255.0, green: 207.0 / 255.0, blue: 207.0 / 255.0, alpha: 0.72)
        static let scrollerThumbHover = NSColor(calibratedRed: 176.0 / 255.0, green: 176.0 / 255.0, blue: 176.0 / 255.0, alpha: 0.88)
        static let scrollerThumbActive = NSColor(calibratedRed: 138.0 / 255.0, green: 138.0 / 255.0, blue: 138.0 / 255.0, alpha: 0.96)

        static let terminalBackground = NSColor(
            calibratedRed: 0.04,
            green: 0.06,
            blue: 0.10,
            alpha: 1
        )
        static let terminalForeground = SIMD4<Float>(0.90, 0.94, 0.98, 1)
        static let terminalCursor = SIMD4<Float>(0.49, 0.83, 0.98, 1)
        static let terminalDefaultBackground = SIMD4<Float>(0.04, 0.06, 0.10, 1)

        static let ansiNormal: [SIMD4<Float>] = [
            SIMD4<Float>(0.00, 0.00, 0.00, 1),
            SIMD4<Float>(0.78, 0.18, 0.18, 1),
            SIMD4<Float>(0.18, 0.62, 0.28, 1),
            SIMD4<Float>(0.78, 0.62, 0.20, 1),
            SIMD4<Float>(0.22, 0.42, 0.86, 1),
            SIMD4<Float>(0.68, 0.32, 0.72, 1),
            SIMD4<Float>(0.20, 0.68, 0.72, 1),
            SIMD4<Float>(0.82, 0.82, 0.82, 1),
        ]

        static let ansiBright: [SIMD4<Float>] = [
            SIMD4<Float>(0.30, 0.30, 0.30, 1),
            SIMD4<Float>(1.00, 0.32, 0.32, 1),
            SIMD4<Float>(0.35, 0.85, 0.45, 1),
            SIMD4<Float>(1.00, 0.82, 0.30, 1),
            SIMD4<Float>(0.42, 0.62, 1.00, 1),
            SIMD4<Float>(0.88, 0.50, 0.95, 1),
            SIMD4<Float>(0.40, 0.88, 0.92, 1),
            SIMD4<Float>(1.00, 1.00, 1.00, 1),
        ]
    }

    enum Typography {
        static let terminalFontSizePT: CGFloat = 15
        static let labelFontSizePT: CGFloat = 13
        static let paneHeaderFontSizePT: CGFloat = 12
        static let statusFontSizePT: CGFloat = 12
    }

    enum Space {
        static let terminalTopPX: CGFloat = 8
        static let terminalLeftPX: CGFloat = 6
        static let terminalBottomPX: CGFloat = 8
        static let terminalRightPX: CGFloat = 6
        static let preferencesInsetPX: CGFloat = 24
        static let preferencesGapPX: CGFloat = 14
    }

    enum Component {
        static let preferencesWidthPX: CGFloat = 640
        static let preferencesHeightPX: CGFloat = 480
        static let preferencesControlWidthPX: CGFloat = 240
        static let preferencesStatusHeightPX: CGFloat = 18
        static let preferencesButtonWidthPX: CGFloat = 84
        static let preferencesButtonHeightPX: CGFloat = 30
        static let preferencesTextFieldWidthPX: CGFloat = 160
        static let settingsEditorFontSizePT: CGFloat = 12
        static let glyphAtlasSizePX = 4096
        static let glyphSlotWidthPX = 128
        static let glyphSlotHeightPX = 128
        static let glyphAtlasOversampleScale: CGFloat = 1
        static let glyphSlotPaddingPX: CGFloat = 6
        static let terminalScrollerWidthPX: CGFloat = 12
        static let terminalScrollerThumbWidthPX: CGFloat = 6
        static let terminalScrollerMinThumbHeightPX: CGFloat = 32
        static let terminalTabBarHeightPX: CGFloat = 44
        static let terminalTabHeightPX: CGFloat = 34
        static let terminalTabCornerRadiusPX: CGFloat = 8
        static let terminalTabMinWidthPX: CGFloat = 118
        static let terminalTabMaxWidthPX: CGFloat = 260
        static let terminalTabPlusWidthPX: CGFloat = 28
        static let terminalTabCloseWidthPX: CGFloat = 18
        static let terminalPaneChromeHeightPX: CGFloat = 32
        static let terminalPaneChromeCloseWidthPX: CGFloat = 28
        static let terminalPaneChromeDotSizePX: CGFloat = 8
        static let terminalSplitDividerHitAreaPX: CGFloat = 8
        static let terminalSplitDividerLinePX: CGFloat = 1
        static let radiusSmallPX: CGFloat = 6
        static let radiusMediumPX: CGFloat = 8
        static let hairlinePX: CGFloat = 1
        static let ptyOutputCoalescingDelaySeconds: TimeInterval = 0.006
    }
}

extension SIMD4 where Scalar == Float {
    var cgColor: CGColor {
        CGColor(
            red: CGFloat(x),
            green: CGFloat(y),
            blue: CGFloat(z),
            alpha: CGFloat(w)
        )
    }
}
