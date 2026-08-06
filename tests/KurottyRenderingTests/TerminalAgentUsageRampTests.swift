import AppKit
import XCTest
@testable import KurottyApp

/// The daily usage strip encodes magnitude in colour because height is relative
/// to the window's own peak — the tallest bar is full height whether the day
/// cost ten thousand tokens or ten million.
@MainActor
final class TerminalAgentUsageRampTests: XCTestCase {
    private func themes() -> [(String, DesignTokens.ChromeTheme)] {
        [("dark", .dark), ("light", .light)]
    }

    private func srgb(_ color: NSColor) throws -> NSColor {
        try XCTUnwrap(color.usingColorSpace(.sRGB))
    }

    /// WCAG 1.4.11: the bars are meaningful graphics, so even the quietest one
    /// has to be distinguishable from the sidebar it is drawn on.
    private func contrastRatio(_ a: NSColor, _ b: NSColor) throws -> Double {
        func luminance(_ color: NSColor) throws -> Double {
            let resolved = try srgb(color)
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(resolved.redComponent)
                + 0.7152 * channel(resolved.greenComponent)
                + 0.0722 * channel(resolved.blueComponent)
        }
        let first = try luminance(a)
        let second = try luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    func testRampEndsLandOnTheThemeStops() throws {
        for (name, theme) in themes() {
            let low = try srgb(TerminalAgentUsageSummaryView.rampColor(forRatio: 0, theme: theme))
            let high = try srgb(TerminalAgentUsageSummaryView.rampColor(forRatio: 1, theme: theme))
            XCTAssertEqual(low.redComponent, try srgb(theme.usageRampLow).redComponent, accuracy: 0.001, name)
            XCTAssertEqual(high.redComponent, try srgb(theme.usageRampHigh).redComponent, accuracy: 0.001, name)
        }
    }

    func testRatiosOutsideZeroToOneClampRatherThanExtrapolate() throws {
        for (name, theme) in themes() {
            let below = try srgb(TerminalAgentUsageSummaryView.rampColor(forRatio: -3, theme: theme))
            let low = try srgb(TerminalAgentUsageSummaryView.rampColor(forRatio: 0, theme: theme))
            let above = try srgb(TerminalAgentUsageSummaryView.rampColor(forRatio: 4, theme: theme))
            let high = try srgb(TerminalAgentUsageSummaryView.rampColor(forRatio: 1, theme: theme))
            XCTAssertEqual(below.redComponent, low.redComponent, accuracy: 0.001, name)
            XCTAssertEqual(above.redComponent, high.redComponent, accuracy: 0.001, name)
        }
    }

    /// The whole point of the change: a heavier day has to read as warmer, not
    /// merely as taller. Red rises and green falls monotonically across the ramp.
    func testHeavierDaysReadWarmerAcrossTheWholeRamp() throws {
        for (name, theme) in themes() {
            var previousRed = -1.0
            var previousGreen = 2.0
            for step in stride(from: 0.0, through: 1.0, by: 0.1) {
                let color = try srgb(
                    TerminalAgentUsageSummaryView.rampColor(forRatio: CGFloat(step), theme: theme)
                )
                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                XCTAssertGreaterThan(red, previousRed, "\(name) red stalled at \(step)")
                XCTAssertLessThan(green, previousGreen, "\(name) green stalled at \(step)")
                previousRed = red
                previousGreen = green
            }
        }
    }

    func testEveryRampStepClearsNonTextContrastOnTheSidebar() throws {
        let nonTextRATIO = 3.0
        for (name, theme) in themes() {
            for step in stride(from: 0.0, through: 1.0, by: 0.25) {
                let color = TerminalAgentUsageSummaryView.rampColor(forRatio: CGFloat(step), theme: theme)
                let ratio = try contrastRatio(color, theme.surfaceSidebar)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    nonTextRATIO,
                    "\(name) ramp at \(step) measured \(ratio):1 on the sidebar"
                )
            }
        }
    }

    /// A heavy day is a magnitude, not a fault. Reusing the status colour would
    /// make "expensive" and "broken" render identically.
    func testTheRampTopIsNotTheErrorStatusColour() throws {
        for (name, theme) in themes() {
            let high = try srgb(theme.usageRampHigh)
            let error = try srgb(theme.error)
            XCTAssertNotEqual(high.redComponent, error.redComponent, accuracy: 0.0, name)
        }
    }
}
