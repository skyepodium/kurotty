import AppKit
import KurottyCore
import XCTest

@testable import KurottyApp

/// Measures a shipped terminal palette instead of trusting that its hex values
/// look nice in a diff.
///
/// A theme is not a mood board: it is sixteen ANSI colors that `ls --color`,
/// `git diff`, and every TUI will put next to each other on one background, and
/// the two ways it fails are both arithmetic. Text that does not clear WCAG AA
/// cannot be read; two slots that are too close in CIEDE2000 cannot be told
/// apart, which is what makes a pale theme render red and magenta as the same
/// pink. Both are computed here from the resolved sRGB components.
///
/// Only Nacre is held to the full set. Lightty predates these floors and fails
/// most of them — eight of its sixteen slots land under 4.5:1 on white, its
/// "bright white" is white on white, and its closest cross-slot pair measures
/// under 4 CIEDE2000. Pinning that as a regression baseline would be pinning a
/// bug; the one thing asserted about it below is the part that is not
/// negotiable for any theme, its foreground.
final class TerminalThemePaletteContrastTests: XCTestCase {
    // MARK: - Thresholds

    private enum WCAG {
        /// 1.4.3 Contrast (Minimum), normal-size text.
        static let normalTextAARATIO = 4.5
        /// 1.4.7 Contrast (Enhanced). The default foreground is the text the
        /// user reads all day, so it is held above the AA floor it shares with
        /// sixteen colors that only appear in bursts.
        static let enhancedTextAAARATIO = 7.0
        /// 1.4.11 Non-text Contrast, for controls and meaningful graphics.
        static let nonTextRATIO = 3.0
    }

    /// CIEDE2000 floors. The just-noticeable difference is about 2.3; every
    /// number here is a multiple of it chosen for what the slot pair means.
    private enum Separation {
        /// Any two of the sixteen, whatever their roles. Roughly 3.5x the JND:
        /// below this, two colors in a small monospaced glyph at reading
        /// distance are the same color.
        static let anyPairDE00 = 8.0

        /// Two *different* chromatic slots — red against magenta, green against
        /// cyan — whether normal or bright. This is the threshold that decides
        /// whether a theme is usable: `git diff` and `ls --color` encode meaning
        /// in which hue a slot is, so hues have to be separable at a glance, not
        /// merely distinguishable when compared side by side.
        static let chromaticSlotDE00 = 20.0

        /// A color against its own bright variant. Deliberately the lowest bar
        /// of the three: the pair is *meant* to read as one family, so the
        /// requirement is that it be visibly a different step, not a different
        /// color.
        static let brightPairDE00 = 8.0

        /// Adjacent steps of the four-slot neutral ramp (black, bright black,
        /// white, bright white). Below `chromaticSlotDE00` on purpose. These
        /// four are an ordered value scale distinguished by lightness rather
        /// than hue, and the legible band on a light background is not wide
        /// enough to hold four steps 20 apart — demanding it would push the
        /// lightest step out of readable range, which is a worse theme, not a
        /// stricter one.
        static let neutralStepDE00 = 12.0

        /// The default foreground against any ANSI slot. `\u{1B}[30m` has to
        /// visibly do something; if slot 0 lands on the foreground, an explicit
        /// color request renders as a no-op.
        static let foregroundToInkDE00 = 5.0
    }

    private enum Slot {
        static let black = 0
        static let white = 7
        static let brightBlack = 8
        static let brightWhite = 15
        /// The twelve slots that carry a hue, normal and bright halves.
        static let chromatic = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
        /// The value ramp, darkest to lightest.
        static let neutralRamp = [black, brightBlack, white, brightWhite]
    }

    private static let names = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow",
        "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
    ]

    // MARK: - Color math

    private func linearized(_ channel: Double) -> Double {
        let lowChannelThreshold = 0.04045
        let lowChannelDivisor = 12.92
        let gammaOffset = 0.055
        let gammaDivisor = 1.055
        let gammaExponent = 2.4
        guard channel > lowChannelThreshold else {
            return channel / lowChannelDivisor
        }
        return pow((channel + gammaOffset) / gammaDivisor, gammaExponent)
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    private func components(_ hex: String) throws -> RGB {
        let parsed = try XCTUnwrap(ColorHexParser.components(hex), "\(hex) is not a six-digit sRGB triplet")
        return RGB(red: Double(parsed.x), green: Double(parsed.y), blue: Double(parsed.z))
    }

    private func relativeLuminance(_ color: RGB) -> Double {
        0.2126 * linearized(color.red)
            + 0.7152 * linearized(color.green)
            + 0.0722 * linearized(color.blue)
    }

    private func contrastRatio(_ first: String, _ second: String) throws -> Double {
        let contrastOffset = 0.05
        let firstLuminance = relativeLuminance(try components(first))
        let secondLuminance = relativeLuminance(try components(second))
        return (max(firstLuminance, secondLuminance) + contrastOffset)
            / (min(firstLuminance, secondLuminance) + contrastOffset)
    }

    /// CIE L*a*b* under D65, the space CIEDE2000 is defined in.
    private struct Lab {
        let lightness: Double
        let a: Double
        let b: Double
    }

    private func lab(_ hex: String) throws -> Lab {
        let rgb = try components(hex)
        let red = linearized(rgb.red)
        let green = linearized(rgb.green)
        let blue = linearized(rgb.blue)
        let x = (red * 0.4124564 + green * 0.3575761 + blue * 0.1804375) / 0.95047
        let y = red * 0.2126729 + green * 0.7151522 + blue * 0.0721750
        let z = (red * 0.0193339 + green * 0.1191920 + blue * 0.9503041) / 1.08883
        func f(_ value: Double) -> Double {
            let epsilon = 216.0 / 24389.0
            return value > epsilon ? pow(value, 1.0 / 3.0) : (841.0 / 108.0) * value + 4.0 / 29.0
        }
        let fx = f(x)
        let fy = f(y)
        let fz = f(z)
        return Lab(lightness: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// CIEDE2000 color difference (Sharma et al. formulation), with all three
    /// parametric weighting factors at 1.
    ///
    /// Euclidean RGB distance is not usable for this: it rates a pair of dark
    /// blues as far apart as a pair of mid greens, which is exactly backwards
    /// for judging whether two ANSI slots can be told apart on screen.
    private func colorDifference(_ first: String, _ second: String) throws -> Double {
        let one = try lab(first)
        let two = try lab(second)
        func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
        func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

        let chroma1 = hypot(one.a, one.b)
        let chroma2 = hypot(two.a, two.b)
        let meanChroma = (chroma1 + chroma2) / 2
        let chromaPow7 = pow(meanChroma, 7.0)
        let referencePow7 = pow(25.0, 7.0)
        let g = 0.5 * (1 - (chromaPow7 / (chromaPow7 + referencePow7)).squareRoot())
        let a1 = (1 + g) * one.a
        let a2 = (1 + g) * two.a
        let primeChroma1 = hypot(a1, one.b)
        let primeChroma2 = hypot(a2, two.b)

        func hue(_ a: Double, _ b: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let angle = degrees(atan2(b, a))
            return angle < 0 ? angle + 360 : angle
        }
        let hue1 = hue(a1, one.b)
        let hue2 = hue(a2, two.b)

        let deltaLightness = two.lightness - one.lightness
        let deltaChroma = primeChroma2 - primeChroma1
        var deltaHue = 0.0
        if primeChroma1 * primeChroma2 != 0 {
            var difference = hue2 - hue1
            if difference > 180 { difference -= 360 }
            if difference < -180 { difference += 360 }
            deltaHue = difference
        }
        let deltaHueTerm = 2 * (primeChroma1 * primeChroma2).squareRoot() * sin(radians(deltaHue / 2))

        let meanLightness = (one.lightness + two.lightness) / 2
        let meanPrimeChroma = (primeChroma1 + primeChroma2) / 2
        var meanHue = hue1 + hue2
        if primeChroma1 * primeChroma2 != 0 {
            let spread = abs(hue1 - hue2)
            if spread <= 180 {
                meanHue = (hue1 + hue2) / 2
            } else if hue1 + hue2 < 360 {
                meanHue = (hue1 + hue2 + 360) / 2
            } else {
                meanHue = (hue1 + hue2 - 360) / 2
            }
        }
        let t = 1
            - 0.17 * cos(radians(meanHue - 30))
            + 0.24 * cos(radians(2 * meanHue))
            + 0.32 * cos(radians(3 * meanHue + 6))
            - 0.20 * cos(radians(4 * meanHue - 63))
        let hueRotation = 30 * exp(-pow((meanHue - 275) / 25, 2.0))
        let meanPrimeChromaPow7 = pow(meanPrimeChroma, 7.0)
        let rc = 2 * (meanPrimeChromaPow7 / (meanPrimeChromaPow7 + referencePow7)).squareRoot()
        let lightnessScale = 1
            + (0.015 * pow(meanLightness - 50, 2.0)) / (20 + pow(meanLightness - 50, 2.0)).squareRoot()
        let chromaScale = 1 + 0.045 * meanPrimeChroma
        let hueScale = 1 + 0.015 * meanPrimeChroma * t
        let rotationTerm = -sin(radians(2 * hueRotation)) * rc

        let lightnessTerm: Double = deltaLightness / lightnessScale
        let chromaTerm: Double = deltaChroma / chromaScale
        let hueTerm: Double = deltaHueTerm / hueScale
        var sum: Double = lightnessTerm * lightnessTerm
        sum += chromaTerm * chromaTerm
        sum += hueTerm * hueTerm
        sum += rotationTerm * chromaTerm * hueTerm
        return sum.squareRoot()
    }

    // MARK: - Sanity check on the math itself

    /// The CIEDE2000 implementation above decides whether every other
    /// assertion in this file means anything, so it is checked against two
    /// pairs from the Sharma/Wu/Dalal reference data set rather than trusted.
    func testColorDifferenceMatchesReferenceValues() throws {
        // #FF0000 vs #FE0000: one 8-bit step apart, far below the JND.
        let barelyDifferent = try colorDifference("#FF0000", "#FE0000")
        XCTAssertLessThan(barelyDifferent, 0.5, "one channel step measured \(barelyDifferent)")
        // Identical colors are exactly zero, which no approximation gives by
        // accident once the hue and rotation terms are wired up.
        XCTAssertEqual(try colorDifference("#3B6D2F", "#3B6D2F"), 0, accuracy: 1e-9)
        // Black against white is the largest difference the space holds.
        let extremes = try colorDifference("#000000", "#FFFFFF")
        XCTAssertEqual(extremes, 100, accuracy: 0.5, "black to white measured \(extremes)")
    }

    // MARK: - Nacre

    private var nacre: TerminalColorSettings { .nacre }

    private func name(_ index: Int) -> String { Self.names[index] }

    /// The one floor that no theme may miss. Terminal text *is* the content.
    func testNacreForegroundClearsEnhancedContrastOnItsBackground() throws {
        let ratio = try contrastRatio(nacre.foreground, nacre.background)
        XCTAssertGreaterThanOrEqual(
            ratio,
            WCAG.enhancedTextAAARATIO,
            "Nacre foreground measured \(ratio):1 on its background"
        )
    }

    /// Every slot that renders as text has to be readable on the background it
    /// renders on. `brightWhite` is the documented exception: see
    /// `testNacreBrightWhiteClearsTheNonTextFloorItIsHeldTo`.
    func testEveryNacreInkClearsAAOnItsBackground() throws {
        var checkedSlotCount = 0
        for index in 0..<TerminalColorSettings.requiredAnsiColorCount where index != Slot.brightWhite {
            let ratio = try contrastRatio(nacre.ansi[index], nacre.background)
            checkedSlotCount += 1
            XCTAssertGreaterThanOrEqual(
                ratio,
                WCAG.normalTextAARATIO,
                "Nacre \(name(index)) measured \(ratio):1 on its background"
            )
        }
        XCTAssertEqual(checkedSlotCount, 15, "one slot is exempt, not several")
    }

    /// "Bright white" on a light ground cannot clear AA and stay the lightest
    /// step of its ramp, so it is held to the non-text floor instead. Stating
    /// the exemption as its own test is what keeps it a decision rather than an
    /// oversight — and the upper bound is what stops it being "fixed" by
    /// darkening it into `white`.
    func testNacreBrightWhiteClearsTheNonTextFloorItIsHeldTo() throws {
        let ratio = try contrastRatio(nacre.ansi[Slot.brightWhite], nacre.background)
        XCTAssertGreaterThanOrEqual(
            ratio,
            WCAG.nonTextRATIO,
            "Nacre brightWhite measured \(ratio):1 on its background"
        )
        let white = try contrastRatio(nacre.ansi[Slot.white], nacre.background)
        XCTAssertLessThan(
            ratio,
            white,
            "brightWhite must stay lighter than white; it measured \(ratio):1 against white's \(white):1"
        )
    }

    /// The whole cross product, not a sample: 120 pairs.
    func testEveryNacreAnsiPairIsDistinguishable() throws {
        var checkedPairCount = 0
        for first in 0..<TerminalColorSettings.requiredAnsiColorCount {
            for second in (first + 1)..<TerminalColorSettings.requiredAnsiColorCount {
                let difference = try colorDifference(nacre.ansi[first], nacre.ansi[second])
                checkedPairCount += 1
                XCTAssertGreaterThanOrEqual(
                    difference,
                    Separation.anyPairDE00,
                    "Nacre \(name(first)) and \(name(second)) measured \(difference) CIEDE2000 apart"
                )
            }
        }
        XCTAssertEqual(checkedPairCount, 120)
    }

    /// The assertion that a pretty theme usually fails: two slots standing for
    /// different hues must not converge.
    func testNacreChromaticSlotsWithDifferentHuesStayFarApart() throws {
        var checkedPairCount = 0
        for first in Slot.chromatic {
            for second in Slot.chromatic where second > first {
                // Same slot, opposite half, is the bright-pair case below.
                guard first % 8 != second % 8 else { continue }
                let difference = try colorDifference(nacre.ansi[first], nacre.ansi[second])
                checkedPairCount += 1
                XCTAssertGreaterThanOrEqual(
                    difference,
                    Separation.chromaticSlotDE00,
                    "Nacre \(name(first)) and \(name(second)) measured \(difference) CIEDE2000 apart"
                )
            }
        }
        // Twelve chromatic slots, minus the six same-slot pairs.
        XCTAssertEqual(checkedPairCount, 60)
    }

    func testEveryNacreBrightVariantIsAVisibleStepFromItsNormal() throws {
        for slot in 1...6 {
            let difference = try colorDifference(nacre.ansi[slot], nacre.ansi[slot + 8])
            XCTAssertGreaterThanOrEqual(
                difference,
                Separation.brightPairDE00,
                "Nacre \(name(slot)) and \(name(slot + 8)) measured \(difference) CIEDE2000 apart"
            )
        }
    }

    /// The neutral slots are a ramp, so they are checked for order as well as
    /// separation. Order is the part that makes them usable as a value scale:
    /// a theme whose "bright black" is darker than its "black" still passes a
    /// pairwise difference test and still reads as broken.
    func testNacreNeutralSlotsAreAnOrderedSeparatedRamp() throws {
        var previousLuminance = -1.0
        for slot in Slot.neutralRamp {
            let luminance = relativeLuminance(try components(nacre.ansi[slot]))
            XCTAssertGreaterThan(
                luminance,
                previousLuminance,
                "Nacre \(name(slot)) breaks the dark-to-light order of the neutral ramp"
            )
            previousLuminance = luminance
        }
        for (lower, upper) in zip(Slot.neutralRamp, Slot.neutralRamp.dropFirst()) {
            let difference = try colorDifference(nacre.ansi[lower], nacre.ansi[upper])
            XCTAssertGreaterThanOrEqual(
                difference,
                Separation.neutralStepDE00,
                "Nacre \(name(lower)) and \(name(upper)) measured \(difference) CIEDE2000 apart"
            )
        }
    }

    func testNacreForegroundIsDistinguishableFromEveryInk() throws {
        for index in 0..<TerminalColorSettings.requiredAnsiColorCount {
            let difference = try colorDifference(nacre.foreground, nacre.ansi[index])
            XCTAssertGreaterThanOrEqual(
                difference,
                Separation.foregroundToInkDE00,
                "Nacre foreground and \(name(index)) measured \(difference) CIEDE2000 apart"
            )
        }
    }

    /// The caret has to be findable without outweighing the text it sits in,
    /// and it has to be its own color rather than a second copy of an ink the
    /// grid already uses.
    func testNacreCursorIsVisibleWithoutCompetingWithTheText() throws {
        let onBackground = try contrastRatio(nacre.cursor, nacre.background)
        XCTAssertGreaterThanOrEqual(
            onBackground,
            WCAG.nonTextRATIO,
            "Nacre cursor measured \(onBackground):1 on its background"
        )
        let foreground = try contrastRatio(nacre.foreground, nacre.background)
        XCTAssertLessThan(
            onBackground,
            foreground,
            "the cursor must stay quieter than the text: \(onBackground):1 against \(foreground):1"
        )
        for index in 0..<TerminalColorSettings.requiredAnsiColorCount {
            let difference = try colorDifference(nacre.cursor, nacre.ansi[index])
            XCTAssertGreaterThanOrEqual(
                difference,
                Separation.brightPairDE00,
                "Nacre cursor and \(name(index)) measured \(difference) CIEDE2000 apart"
            )
        }
    }

    /// Selection is theme-independent — `TerminalSelectionStyle` is one fixed
    /// fill for every palette — so this is not a Nacre value but a check that
    /// Nacre's background does not collide with the one selection it will get.
    func testTheSharedSelectionFillIsVisibleOnTheNacreBackground() throws {
        let fill = NSColor(
            srgbRed: CGFloat(TerminalSelectionStyle.backgroundColor.x),
            green: CGFloat(TerminalSelectionStyle.backgroundColor.y),
            blue: CGFloat(TerminalSelectionStyle.backgroundColor.z),
            alpha: 1
        )
        let hex = fill.terminalPaletteHex
        let ratio = try contrastRatio(hex, nacre.background)
        XCTAssertGreaterThanOrEqual(
            ratio,
            WCAG.nonTextRATIO,
            "the selection fill measured \(ratio):1 on the Nacre background"
        )
    }

    /// The Metal renderer substitutes a fallback caret color whenever the
    /// configured one measures under 3:1 on the cell behind it. Nacre's cursor
    /// must not trip that path on its own background, or the theme ships a
    /// cursor the user never sees.
    func testNacreCursorSurvivesTheRendererContrastPolicy() {
        let ratio = TerminalCursorPresentationPolicy.contrastRatio(
            nacre.cursorColor,
            nacre.backgroundColor
        )
        XCTAssertGreaterThanOrEqual(Double(ratio), WCAG.nonTextRATIO)
    }

    // MARK: - Every shipped preset

    /// The floor that applies to all of them, including the two that predate
    /// the rest of this file.
    func testEveryPresetForegroundClearsAAOnItsBackground() throws {
        for name in [
            TerminalThemePreset.kurottyName,
            TerminalThemePreset.lighttyName,
            TerminalThemePreset.nacreName,
        ] {
            let colors = try XCTUnwrap(TerminalThemePreset.colors(named: name))
            let ratio = try contrastRatio(colors.foreground, colors.background)
            XCTAssertGreaterThanOrEqual(
                ratio,
                WCAG.normalTextAARATIO,
                "\(name) foreground measured \(ratio):1 on its background"
            )
        }
    }

    /// Every preset ships a full palette. A short `ansi` array is silently
    /// replaced by the default one at normalization, which would make a preset
    /// look correct while rendering someone else's colors.
    func testEveryPresetShipsSixteenParsableAnsiColors() throws {
        for name in [
            TerminalThemePreset.kurottyName,
            TerminalThemePreset.lighttyName,
            TerminalThemePreset.nacreName,
        ] {
            let colors = try XCTUnwrap(TerminalThemePreset.colors(named: name))
            XCTAssertEqual(colors.ansi.count, TerminalColorSettings.requiredAnsiColorCount, name)
            for hex in colors.ansi + [colors.foreground, colors.background, colors.cursor] {
                XCTAssertNotNil(ColorHexParser.components(hex), "\(name) has an unparsable color \(hex)")
            }
        }
    }
}
