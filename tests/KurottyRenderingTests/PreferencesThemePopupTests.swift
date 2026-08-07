import XCTest
@testable import KurottyApp

/// The theme popup's order used to be spelled out in three coordinated
/// switches; `PreferencesThemePopup` is now the single source. These tests
/// pin the mappings the switches used to encode.
final class PreferencesThemePopupTests: XCTestCase {
    func testEntriesKeepPresetOrderWithCustomLast() {
        XCTAssertEqual(
            PreferencesThemePopup.entries.map(\.presetName),
            [
                TerminalThemePreset.kurottyName,
                TerminalThemePreset.lighttyName,
                TerminalThemePreset.nacreName,
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
        XCTAssertEqual(PreferencesThemePopup.presetName(atIndex: 2), TerminalThemePreset.nacreName)
        XCTAssertEqual(PreferencesThemePopup.presetName(atIndex: 3), TerminalThemePreset.customName)
        XCTAssertEqual(PreferencesThemePopup.presetName(atIndex: 99), TerminalThemePreset.customName)
    }

    func testPresetNameToIndexMatchesTheFormerSyncSwitch() {
        XCTAssertEqual(PreferencesThemePopup.index(ofPresetName: TerminalThemePreset.kurottyName), 0)
        XCTAssertEqual(PreferencesThemePopup.index(ofPresetName: TerminalThemePreset.lighttyName), 1)
        XCTAssertEqual(PreferencesThemePopup.index(ofPresetName: TerminalThemePreset.nacreName), 2)
        XCTAssertEqual(PreferencesThemePopup.index(ofPresetName: TerminalThemePreset.customName), 3)
        XCTAssertEqual(
            PreferencesThemePopup.index(ofPresetName: "kuro-dark"),
            3,
            "non-selectable stored names fall back to the custom slot"
        )
    }

    /// Every selectable entry has to resolve to a palette. An entry whose
    /// preset name has no colors selects a theme that changes nothing, which
    /// is the failure mode a popup driven by a list rather than a switch is
    /// supposed to make impossible.
    func testEverySelectableEntryExceptCustomResolvesToAPalette() {
        for entry in PreferencesThemePopup.entries where entry.presetName != TerminalThemePreset.customName {
            XCTAssertNotNil(
                TerminalThemePreset.colors(named: entry.presetName),
                "\(entry.presetName) is offered in the popup but has no palette"
            )
        }
        XCTAssertNil(TerminalThemePreset.colors(named: TerminalThemePreset.customName))
    }
}
