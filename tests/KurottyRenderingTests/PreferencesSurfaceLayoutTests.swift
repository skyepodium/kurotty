import AppKit
import XCTest
@testable import KurottyApp

/// The settings surface is hosted in a tab now, so it is laid out at whatever
/// width the window happens to be. These assert the geometry that broke when it
/// moved out of its old fixed-size window.
@MainActor
final class PreferencesSurfaceLayoutTests: XCTestCase {
    private func laidOutSurface(width: CGFloat) -> PreferencesView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        let view = PreferencesView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return view
    }

    /// Depth-first search for the scroll view that hosts the settings cards.
    private func detailScrollView(in view: NSView) throws -> NSScrollView {
        func find(_ v: NSView) -> NSScrollView? {
            if let scroll = v as? NSScrollView { return scroll }
            for child in v.subviews { if let hit = find(child) { return hit } }
            return nil
        }
        return try XCTUnwrap(find(view))
    }

    /// The regression: `navDivider` is an `NSBox` separator, and a vertical rule
    /// has no thickness AppKit can infer. With only its leading edge pinned and
    /// the scroll view hung off its trailing edge, it absorbed every spare
    /// point — over a thousand of them in a wide tab — and shoved the settings
    /// content to the far right behind a dead band.
    func testTheNavDividerStaysAHairlineNoMatterHowWideTheTabIs() throws {
        for width in [900.0, 1400.0, 2200.0] {
            let view = laidOutSurface(width: width)
            let scroll = try detailScrollView(in: view)
            let contentStart = scroll.convert(scroll.bounds, to: view).minX
            let navWidth = DesignTokens.Component.preferencesSidebarWidthPX
            XCTAssertLessThanOrEqual(
                contentStart - navWidth,
                DesignTokens.Component.hairlinePX * 2,
                "at \(width)pt the content began \(contentStart)pt in, a nav of \(navWidth)pt away"
            )
        }
    }

    /// The nav rows fill their column rather than sitting as small pills in a
    /// wide empty band.
    func testTheNavRowsFillTheirColumn() throws {
        let view = laidOutSurface(width: 1400)
        let expected = DesignTokens.Component.preferencesSidebarWidthPX
            - DesignTokens.Component.preferencesNavTrailingInsetPX
        func buttons(_ v: NSView) -> [NSButton] {
            v.subviews.flatMap { child -> [NSButton] in
                (child as? NSButton).map { [$0] } ?? buttons(child)
            }
        }
        // Identified by type, not by bezel: the nav rows stopped being recessed
        // buttons when they took the window's capsule selection language, and a
        // bezel filter would have silently matched nothing.
        let navButtons = buttons(view).compactMap { $0 as? PreferencesNavRowButton }
        XCTAssertFalse(navButtons.isEmpty)
        for button in navButtons {
            XCTAssertEqual(button.bounds.width, expected, accuracy: 1, "nav row width")
        }
    }
}
