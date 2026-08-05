import XCTest
@testable import KurottyApp

/// The theme popup's order used to be spelled out in three coordinated
/// switches; `PreferencesThemePopup` is now the single source. These tests
/// pin the mappings the switches used to encode.
final class PreferencesThemePopupTests: XCTestCase {
    func testEntriesKeepKurottyLighttyCustomOrderWithCustomLast() {
        XCTAssertEqual(
            PreferencesThemePopup.entries.map(\.presetName),
            [
                TerminalThemePreset.kurottyName,
                TerminalThemePreset.lighttyName,
                TerminalThemePreset.customName,
            ]
        )
        XCTAssertEqual(
            PreferencesThemePopup.entries.last?.presetName,
            TerminalThemePreset.customName,
            "custom must stay last: it is the fallback index for unknown names"
        )
    }

    func testIndexToPresetNameMatchesTheFormerSelectionSwitch() {
        XCTAssertEqual(PreferencesThemePopup.presetName(atIndex: 0), TerminalThemePreset.kurottyName)
        XCTAssertEqual(PreferencesThemePopup.presetName(atIndex: 1), TerminalThemePreset.lighttyName)
        XCTAssertEqual(PreferencesThemePopup.presetName(atIndex: 2), TerminalThemePreset.customName)
        XCTAssertEqual(PreferencesThemePopup.presetName(atIndex: 99), TerminalThemePreset.customName)
    }

    func testPresetNameToIndexMatchesTheFormerSyncSwitch() {
        XCTAssertEqual(PreferencesThemePopup.index(ofPresetName: TerminalThemePreset.kurottyName), 0)
        XCTAssertEqual(PreferencesThemePopup.index(ofPresetName: TerminalThemePreset.lighttyName), 1)
        XCTAssertEqual(PreferencesThemePopup.index(ofPresetName: TerminalThemePreset.customName), 2)
        XCTAssertEqual(
            PreferencesThemePopup.index(ofPresetName: "kuro-dark"),
            2,
            "non-selectable stored names fall back to the custom slot"
        )
    }
}
