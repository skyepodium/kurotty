import AppKit
import XCTest
@testable import KurottyApp

/// The file explorer used AppKit's stock disclosure triangle while the history
/// list replaced it with a themed chevron. A system triangle is drawn in a
/// system colour, so on a themed panel it lands somewhere between invisible and
/// wrong -- which is how it was reported.
@MainActor
final class SidebarDisclosureParityTests: XCTestCase {
    private func disclosureButton(in outline: NSOutlineView) -> NSButton? {
        outline.makeView(
            withIdentifier: NSOutlineView.disclosureButtonIdentifier,
            owner: outline
        ) as? NSButton
    }

    func testTheExplorerDisclosureTakesTheChromeTintRatherThanASystemColour() throws {
        let outline = TerminalFileExplorerOutlineView()
        for theme in [DesignTokens.ChromeTheme.dark, .light, .nacre] {
            outline.disclosureTintColor = theme.textTertiary
            let button = try XCTUnwrap(disclosureButton(in: outline))
            XCTAssertEqual(button.contentTintColor, theme.textTertiary)
            XCTAssertNotNil(button.image, "collapsed chevron")
            XCTAssertNotNil(button.alternateImage, "expanded chevron")
        }
    }

    /// Both sidebars are the same furniture in the same window, so they must
    /// disclose at the same size as well as in the same colour.
    func testBothSidebarsDiscloseAtTheSameSize() throws {
        let explorer = TerminalFileExplorerOutlineView()
        explorer.disclosureTintColor = DesignTokens.ChromeTheme.light.textTertiary
        let button = try XCTUnwrap(disclosureButton(in: explorer))
        let expected = DesignTokens.Component.commandHistoryDisclosureBoxSizePX
        XCTAssertEqual(button.frame.width, expected, accuracy: 0.01)
        XCTAssertEqual(button.frame.height, expected, accuracy: 0.01)
    }
}
