import XCTest
@testable import KurottyApp
import KurottyCore

@MainActor
final class TerminalTextContrastPolicyTests: XCTestCase {
    func testDefaultLightForegroundRemainsReadableOnAnsiBlackPromptSegment() {
        let defaultStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0x1F / 255, 0x1E / 255, 0x2D / 255, 1),
            background: SIMD4<Float>(1, 1, 1, 1)
        )
        let ansiBlack = SIMD4<Float>(0x0C / 255, 0x0C / 255, 0x12 / 255, 1)
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: defaultStyle,
            ansiColors: [ansiBlack] + Array(repeating: SIMD4<Float>.zero, count: 15),
            maxScrollbackRows: 10
        )

        interpreter.interpret("\u{1B}[40mskyepodium")

        let promptCell = interpreter.screen.cells[0][0]
        XCTAssertEqual(promptCell.style.foreground, defaultStyle.foreground)
        XCTAssertEqual(promptCell.style.background, ansiBlack)
        let visible = TerminalTextContrastPolicy.visibleForeground(
            for: promptCell.style,
            defaultStyle: defaultStyle
        )
        XCTAssertGreaterThanOrEqual(
            TerminalCursorPresentationPolicy.contrastRatio(visible, promptCell.style.effectiveBackground),
            4.5
        )
    }

    func testExplicitForegroundIsPreservedWhenItClearsTheEmergencyFloor() {
        let defaultStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.1, 0.1, 0.1, 1),
            background: SIMD4<Float>(1, 1, 1, 1)
        )
        let explicitForeground = SIMD4<Float>(0.55, 0.55, 0.55, 1)
        let explicitBackground = SIMD4<Float>(0.12, 0.12, 0.12, 1)
        let style = TerminalTextStyle(
            foreground: explicitForeground,
            background: explicitBackground,
            foregroundSource: .ansi,
            backgroundSource: .ansi
        )

        XCTAssertEqual(
            TerminalTextContrastPolicy.visibleForeground(for: style, defaultStyle: defaultStyle),
            explicitForeground
        )
    }

    func testCatastrophicExplicitPairFallsBackToReadableThemeForeground() {
        let defaultForeground = SIMD4<Float>(0.92, 0.92, 0.92, 1)
        let defaultStyle = TerminalTextStyle(
            foreground: defaultForeground,
            background: SIMD4<Float>(0.1, 0.1, 0.1, 1)
        )
        let style = TerminalTextStyle(
            foreground: SIMD4<Float>(0.08, 0.08, 0.08, 1),
            background: SIMD4<Float>(0.05, 0.05, 0.05, 1),
            foregroundSource: .rgb,
            backgroundSource: .rgb
        )

        XCTAssertEqual(
            TerminalTextContrastPolicy.visibleForeground(for: style, defaultStyle: defaultStyle),
            defaultForeground
        )
    }

    func testCatastrophicInversePairAlsoFallsBackToReadableThemeForeground() {
        let defaultForeground = SIMD4<Float>(0.92, 0.92, 0.92, 1)
        let defaultStyle = TerminalTextStyle(
            foreground: defaultForeground,
            background: SIMD4<Float>(0.1, 0.1, 0.1, 1)
        )
        let style = TerminalTextStyle(
            foreground: SIMD4<Float>(0.05, 0.05, 0.05, 1),
            background: SIMD4<Float>(0.08, 0.08, 0.08, 1),
            foregroundSource: .rgb,
            backgroundSource: .rgb,
            inverse: true
        )

        XCTAssertEqual(
            TerminalTextContrastPolicy.visibleForeground(for: style, defaultStyle: defaultStyle),
            defaultForeground
        )
    }

    func testCatastrophicAnsiPairIsMadeReadable() {
        let ansiBlack = SIMD4<Float>(0.05, 0.05, 0.05, 1)
        let defaultStyle = TerminalTextStyle(
            foreground: ansiBlack,
            background: SIMD4<Float>(1, 1, 1, 1)
        )
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: defaultStyle,
            ansiColors: [ansiBlack] + Array(repeating: SIMD4<Float>.zero, count: 15),
            maxScrollbackRows: 10
        )

        interpreter.interpret("\u{1B}[30;40mA")

        let style = interpreter.screen.cells[0][0].style
        XCTAssertEqual(style.foregroundSource, .ansi)
        XCTAssertGreaterThanOrEqual(
            TerminalCursorPresentationPolicy.contrastRatio(
                TerminalTextContrastPolicy.visibleForeground(for: style, defaultStyle: defaultStyle),
                style.effectiveBackground
            ),
            4.5
        )
    }

    func testDefaultForegroundIsUnchangedOnDefaultBackground() {
        let defaultStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.1, 0.1, 0.1, 1),
            background: SIMD4<Float>(0.12, 0.12, 0.12, 1)
        )

        XCTAssertEqual(
            TerminalTextContrastPolicy.visibleForeground(for: defaultStyle, defaultStyle: defaultStyle),
            defaultStyle.effectiveForeground
        )
    }
}
