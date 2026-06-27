import AppKit
import simd

enum DesignTokens {
    enum Color {
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
        static let glyphAtlasSizePX = 3072
        static let glyphSlotWidthPX = 192
        static let glyphSlotHeightPX = 192
        static let glyphAtlasOversampleScale: CGFloat = 1
        static let glyphSlotPaddingPX: CGFloat = 6
        static let terminalScrollerWidthPX: CGFloat = 12
        static let terminalScrollerThumbWidthPX: CGFloat = 6
        static let terminalScrollerMinThumbHeightPX: CGFloat = 32
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
