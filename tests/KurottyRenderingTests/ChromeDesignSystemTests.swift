import AppKit
import XCTest
@testable import KurottyApp

/// Covers the shared design-system helpers introduced with the editor, search
/// bar, chrome button, and preferences pass: the icon ramp, the floating
/// elevation, the three allowed motions, and the surfaces that consume them.
final class ChromeDesignSystemTests: XCTestCase {
    // MARK: - Icon ramp

    func testIconSizeClassPinsTheFourChromeSizes() {
        XCTAssertEqual(Icon.SizeClass.micro.pointSizePT, 9)
        XCTAssertEqual(Icon.SizeClass.small.pointSizePT, 11)
        XCTAssertEqual(Icon.SizeClass.regular.pointSizePT, 13)
        XCTAssertEqual(Icon.SizeClass.large.pointSizePT, 20)

        XCTAssertEqual(Icon.SizeClass.micro.weight, .semibold)
        XCTAssertEqual(Icon.SizeClass.small.weight, .medium)
        XCTAssertEqual(Icon.SizeClass.regular.weight, .regular)
        XCTAssertEqual(Icon.SizeClass.large.weight, .regular)
    }

    func testIconBuildsSymbolsAndReturnsNilForUnknownNames() {
        XCTAssertNotNil(Icon.symbol(IconSymbol.close, .small, tint: .white))
        XCTAssertNotNil(Icon.symbol(IconSymbol.breadcrumbSeparator, .micro, tint: .white))
        XCTAssertNil(Icon.symbol("kurotty.not.a.real.symbol", .small, tint: .white))
    }

    // MARK: - Elevation

    @MainActor
    func testFloatingElevationDiffersBetweenLightAndDarkChrome() {
        let dark = DesignTokens.Elevation.floating(for: .dark)
        let light = DesignTokens.Elevation.floating(for: .light)

        XCTAssertEqual(dark.opacity, 0.28)
        XCTAssertEqual(dark.radiusPX, 16)
        XCTAssertEqual(dark.downwardOffsetPX, 4)
        XCTAssertEqual(light.opacity, 0.14)
        XCTAssertEqual(light.radiusPX, 12)
        XCTAssertEqual(light.downwardOffsetPX, 3)
    }

    @MainActor
    func testFloatingElevationPushesTheShadowDownwardInLayerGeometry() {
        let layer = CALayer()
        DesignTokens.Elevation.floating(for: .dark).apply(to: layer)

        // AppKit's unflipped layer space needs a negative height for a shadow
        // that falls below the surface.
        XCTAssertEqual(layer.shadowOffset.height, -4)
        XCTAssertEqual(layer.shadowRadius, 16)
    }

    // MARK: - Motion

    @MainActor
    func testOnlyTheThreeAllowedMotionDurationsExist() {
        XCTAssertEqual(DesignTokens.Motion.sectionSwitchDurationMS, 160)
        XCTAssertEqual(DesignTokens.Motion.sectionListFadeDurationMS, 80)
        XCTAssertEqual(DesignTokens.Motion.disclosureRotationDurationMS, 150)
        XCTAssertEqual(DesignTokens.Motion.statusValueCrossfadeDurationMS, 120)
        XCTAssertEqual(DesignTokens.Motion.seconds(fromMS: 160), 0.16, accuracy: 0.0001)
    }

    @MainActor
    func testImplicitLayerAnimationsAreDisabledForFillAndGeometry() {
        let layer = CALayer()
        ChromeMotion.disableImplicitAnimations(on: layer)

        for key in ["backgroundColor", "position", "bounds"] {
            XCTAssertTrue(layer.actions?[key] is NSNull, "\(key) still animates implicitly")
        }
    }

    @MainActor
    func testDisclosureChevronRotatesBetweenZeroAndNinetyDegrees() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))

        ChromeMotion.rotateDisclosureChevron(view, expanded: false, animated: false)
        let collapsed = view.layer?.transform ?? CATransform3DIdentity
        ChromeMotion.rotateDisclosureChevron(view, expanded: true, animated: false)
        let expanded = view.layer?.transform ?? CATransform3DIdentity

        XCTAssertTrue(CATransform3DIsIdentity(collapsed))
        XCTAssertFalse(CATransform3DIsIdentity(expanded))
        // 90 degrees about z: cos(90) == 0, sin(90) == 1.
        XCTAssertEqual(expanded.m11, 0, accuracy: 0.0001)
        XCTAssertEqual(expanded.m12, 1, accuracy: 0.0001)
    }

    @MainActor
    func testSidebarSectionChangeUnhidesTheIncomingListWithoutSlidingIt() {
        let underline = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 2))
        let outgoing = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let incoming = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        incoming.isHidden = true

        SidebarMotion.animateSectionChange(
            underline: underline,
            toFrame: NSRect(x: 40, y: 0, width: 60, height: 2),
            outgoing: outgoing,
            incoming: incoming
        )

        XCTAssertFalse(incoming.isHidden)
        XCTAssertEqual(incoming.alphaValue, 0)
        // Peers, not a stack: the incoming list must not be offset horizontally.
        XCTAssertEqual(incoming.frame.origin.x, 0)
    }

    // MARK: - ChromeIconButton

    @MainActor
    func testChromeIconButtonAdoptsTheThemeRamp() {
        let button = ChromeIconButton(frame: .zero)
        button.applyChromeTheme(.light)

        XCTAssertEqual(button.normalTintColor, DesignTokens.ChromeTheme.light.textTertiary)
        XCTAssertEqual(button.hoverTintColor, DesignTokens.ChromeTheme.light.textPrimary)
        XCTAssertEqual(button.hoverBackgroundColor, DesignTokens.ChromeTheme.light.hoverFill)
        XCTAssertEqual(button.pressBackgroundColor, DesignTokens.ChromeTheme.light.pressFill)
        XCTAssertEqual(button.focusRingColor, DesignTokens.ChromeTheme.light.focusRing)
    }

    @MainActor
    func testChromeIconButtonKeepsAMinimumHitTargetWhenDrawnSmaller() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
        let button = ChromeIconButton(frame: NSRect(x: 20, y: 20, width: 18, height: 18))
        host.addSubview(button)

        // Three points outside the 18pt frame, inside the 24pt hit target.
        XCTAssertIdentical(host.hitTest(NSPoint(x: 18, y: 29)), button)
        XCTAssertIdentical(host.hitTest(NSPoint(x: 29, y: 18)), button)
        XCTAssertIdentical(host.hitTest(NSPoint(x: 5, y: 5)), host)
    }

    @MainActor
    func testDisabledChromeIconButtonDimsRatherThanDisappears() throws {
        let button = ChromeIconButton(frame: .zero)
        button.applyChromeTheme(.dark)
        button.isEnabled = false

        let tint = try XCTUnwrap(button.contentTintColor)
        XCTAssertEqual(tint.alphaComponent, ChromeIconButton.disabledTintAlphaRATIO, accuracy: 0.001)
    }

    // MARK: - Search bar

    @MainActor
    func testSearchBarUsesTheFloatingElevationAndTheLargeRadius() {
        let searchBar = TerminalSearchBarView()
        searchBar.applyChromeTheme(.dark)
        searchBar.layoutSubtreeIfNeeded()

        XCTAssertEqual(searchBar.layer?.cornerRadius, DesignTokens.Radius.lgPX)
        XCTAssertEqual(searchBar.layer?.shadowRadius, DesignTokens.Elevation.floatingDark.radiusPX)
        XCTAssertEqual(searchBar.layer?.shadowOpacity, DesignTokens.Elevation.floatingDark.opacity)
        XCTAssertEqual(searchBar.fittingSize.height, 40)
    }

    @MainActor
    func testSearchBarShowsAFailedSearchInErrorButAnEmptyQueryInQuietText() throws {
        let searchBar = TerminalSearchBarView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
        searchBar.applyChromeTheme(.dark)
        let label = try XCTUnwrap(resultCountLabel(in: searchBar))

        searchBar.update(summary: .empty)
        XCTAssertEqual(label.textColor, DesignTokens.ChromeTheme.dark.textTertiary)

        searchBar.present(query: "no-such-text")
        searchBar.update(summary: .empty)
        XCTAssertEqual(label.textColor, DesignTokens.ChromeTheme.dark.error)

        searchBar.update(summary: TerminalSearchSummary(currentIndex: 0, totalMatches: 3))
        XCTAssertEqual(label.textColor, DesignTokens.ChromeTheme.dark.textTertiary)
    }

    // MARK: - Code editor

    @MainActor
    func testEditorPathBarRendersABreadcrumbRatherThanASlashJoinedPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-breadcrumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("example.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let editor = TerminalCodeEditorView()
        editor.applyChromeTheme(.dark)
        editor.load(url: file)
        let pathBar = try XCTUnwrap(editorPathBar(in: editor))
        let value = pathBar.attributedStringValue

        XCTAssertTrue(value.string.hasSuffix("example.swift"))
        XCTAssertFalse(value.string.contains("/"))
        XCTAssertTrue(value.string.contains(directory.lastPathComponent))
        XCTAssertEqual(pathBar.lineBreakMode, .byTruncatingHead)
    }

    @MainActor
    func testEditorPathBarIsARealBarWithAHairlineAndNoGapToTheContent() throws {
        let editor = TerminalCodeEditorView()
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        editor.applyChromeTheme(.dark)
        editor.layoutSubtreeIfNeeded()
        let pathBar = try XCTUnwrap(editorPathBar(in: editor))
        let container = try XCTUnwrap(pathBar.superview)
        let scrollView = try XCTUnwrap(editor.subviews.compactMap { $0 as? NSScrollView }.first)

        XCTAssertEqual(container.frame.height, 28)
        XCTAssertEqual(container.frame.width, editor.bounds.width)
        // Flipped-free AppKit coordinates: the bar sits at the top, the content
        // starts exactly where the bar ends.
        XCTAssertEqual(container.frame.maxY, editor.bounds.maxY)
        XCTAssertEqual(scrollView.frame.maxY, container.frame.minY)

        let hairline = try XCTUnwrap(container.subviews.first { $0 !== pathBar })
        XCTAssertEqual(hairline.frame.height, DesignTokens.Component.hairlinePX)
        XCTAssertEqual(hairline.frame.minY, container.bounds.minY)
    }

    @MainActor
    func testEditorGutterIsNarrowerAndUntinted() throws {
        let editor = TerminalCodeEditorView()
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        editor.applyChromeTheme(.dark)
        editor.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(editor.subviews.compactMap { $0 as? NSScrollView }.first)
        let ruler = try XCTUnwrap(scrollView.verticalRulerView)

        XCTAssertEqual(ruler.ruleThickness, 40)
    }

    // MARK: - Preferences

    func testPreferencesSurfaceAndControlMetricsMatchTheDesignSpec() {
        XCTAssertEqual(DesignTokens.Component.preferencesWidthPX, 720)
        XCTAssertEqual(DesignTokens.Component.preferencesHeightPX, 852)
        // Settings is a tab now, so the content column has a ceiling instead of
        // the window having a size. `PreferencesSettingsTabTests` covers the
        // elastic behavior below that ceiling.
        XCTAssertEqual(DesignTokens.Component.preferencesContentMaxWidthPX, 720)
        XCTAssertEqual(DesignTokens.Component.preferencesControlWidthPX, 220)
        XCTAssertEqual(DesignTokens.Component.preferencesButtonWidthPX, 84)
        XCTAssertEqual(DesignTokens.Component.preferencesButtonHeightPX, 28)
        XCTAssertEqual(DesignTokens.Component.preferencesStatusHeightPX, 16)
        XCTAssertEqual(DesignTokens.Component.preferencesTextFieldWidthPX, 160)
        XCTAssertEqual(DesignTokens.Component.preferencesNumericFieldWidthPX, 96)
    }

    func testPreferencesNoLongerPaintsSystemControlBackgroundCards() throws {
        let source = try preferencesSource()

        XCTAssertFalse(source.contains("NSColor.controlBackgroundColor"))
        XCTAssertTrue(source.contains("theme.surfaceRaised.cgColor"))
        XCTAssertTrue(source.contains("DesignTokens.Radius.mdPX"))
    }

    // MARK: - Helpers

    @MainActor
    private func resultCountLabel(in searchBar: TerminalSearchBarView) -> NSTextField? {
        searchBar.subviews
            .compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews }
            .compactMap { $0 as? NSTextField }
            .first(where: { !$0.isEditable })
    }

    @MainActor
    private func editorPathBar(in editor: TerminalCodeEditorView) -> NSTextField? {
        editor.subviews
            .flatMap { [$0] + $0.subviews }
            .compactMap { $0 as? NSTextField }
            .first
    }

    private func preferencesSource() throws -> String {
        // PreferencesView was split into panes/controls files; the card
        // styling this test asserts lives in the controls file.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            root.deleteLastPathComponent()
        }
        let fileNames = [
            "PreferencesView.swift",
            "PreferencesViewPanes.swift",
            "PreferencesViewControls.swift",
        ]
        return try fileNames.map { fileName in
            try String(
                contentsOf: root
                    .appendingPathComponent("Sources/KurottyApp")
                    .appendingPathComponent(fileName),
                encoding: .utf8
            )
        }.joined()
    }
}
