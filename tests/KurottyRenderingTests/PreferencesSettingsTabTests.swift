import AppKit
import XCTest
@testable import KurottyApp

/// Settings hosted as a center tab: opening and reuse, the containment contract
/// it shares with editor and transcript tabs, and Find landing on the settings
/// query field rather than on a terminal that is not there.
@MainActor
final class PreferencesSettingsTabTests: XCTestCase {
    private func makeWindowController() -> TerminalWindowController {
        let session = TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        return TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: session),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
    }

    func testOpeningSettingsAddsATabHostingTheSettingsSurface() throws {
        let controller = makeWindowController()
        defer { controller.close() }

        let item = controller.openSettingsTab()

        XCTAssertEqual(controller.tabView.numberOfTabViewItems, 2)
        XCTAssertTrue(controller.tabView.selectedTabViewItem === item)
        XCTAssertNotNil(controller.settingsView(in: item))
        XCTAssertEqual(
            item.label,
            PreferencesCopy.string(.settingsTitle, language: AppLocalization.language)
        )
    }

    /// One settings surface per window. Two would be two editors of the same
    /// file on disk, racing each other's autosave.
    func testOpeningSettingsTwiceReusesTheSameTab() throws {
        let controller = makeWindowController()
        defer { controller.close() }

        let first = controller.openSettingsTab()
        controller.newTab()
        let reopened = controller.openSettingsTab()

        XCTAssertTrue(first === reopened)
        XCTAssertEqual(controller.tabView.numberOfTabViewItems, 3, "reuse must not add a second settings tab")
        XCTAssertTrue(controller.tabView.selectedTabViewItem === reopened, "reuse reveals the tab")
    }

    /// A settings tab hosts no `SplitTerminalView`, so every controller path
    /// that needs a terminal must fall through it exactly like an editor tab.
    func testTerminalOnlyActionsAreNoOpsWhileTheSettingsTabIsSelected() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        let item = controller.openSettingsTab()

        XCTAssertTrue(controller.tabView.selectedTabViewItem === item)
        XCTAssertNil(controller.currentSplitView())

        controller.splitVertically()
        controller.splitHorizontally()
        controller.sendTextToActivePane("echo should-not-reach-a-pane")

        XCTAssertEqual(
            controller.tabView.numberOfTabViewItems,
            2,
            "splitting on the settings tab must not create panes or tabs"
        )
        XCTAssertEqual(controller.selectedLayoutSlotCount, 0)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder.isEmpty)
    }

    /// Find means "find in what is on screen". The settings tab has one search,
    /// and it is not the terminal's.
    func testFindFocusesTheSettingsQueryFieldWhileTheSettingsTabIsSelected() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        let item = controller.openSettingsTab()
        let settings = try XCTUnwrap(controller.settingsView(in: item))
        // Focus is parked on the window itself so the assertion measures what
        // Find did rather than wherever AppKit happened to leave it.
        try XCTUnwrap(controller.window).makeFirstResponder(nil)
        XCTAssertFalse(settings.searchFieldIsFocusedForTesting)

        controller.findTerminalOutput()

        XCTAssertTrue(settings.searchFieldIsFocusedForTesting)
    }

    func testTheSettingsTabIsDiscoverableThroughTheController() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        XCTAssertFalse(controller.hasOpenSettingsTab)

        let item = controller.openSettingsTab()

        XCTAssertTrue(controller.hasOpenSettingsTab)
        XCTAssertTrue(controller.settingsTabItem === item)
    }

    /// A language switch has to reach both halves: the tab label belongs to the
    /// window, the page copy belongs to the view.
    func testALanguageSwitchRetranslatesTheTabLabelAndThePane() throws {
        let originalPreference = AppLocalization.preference
        defer { AppLocalization.preference = originalPreference }
        AppLocalization.preference = .english
        let controller = makeWindowController()
        defer { controller.close() }
        let item = controller.openSettingsTab()
        let settings = try XCTUnwrap(controller.settingsView(in: item))
        XCTAssertEqual(item.label, PreferencesCopy.string(.settingsTitle, language: .english))

        AppLocalization.preference = .korean
        controller.refreshSettingsTabLocalization()

        XCTAssertEqual(item.label, PreferencesCopy.string(.settingsTitle, language: .korean))
        XCTAssertEqual(
            settings.selectedNavTitlesForTesting,
            [PreferencesCopy.string(.terminalCategory, language: .korean)]
        )
    }
}

/// Navigation state of the settings surface: which pane the nav is showing and
/// what the content column does with the width it is given.
@MainActor
final class PreferencesNavigationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-preferences-nav-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testExactlyOneNavRowIsSelectedAndItIsTheOpenPane() throws {
        let view = try makeView()

        XCTAssertEqual(view.selectedCategoryForTesting, .terminal)
        XCTAssertEqual(view.selectedNavTitlesForTesting, [englishCopy(.terminalCategory)])

        view.clickNavRowForTesting(.window)

        XCTAssertEqual(view.selectedCategoryForTesting, .window)
        XCTAssertEqual(view.selectedNavTitlesForTesting, [englishCopy(.windowCategory)])
    }

    func testClickingANavRowReplacesTheContentWithThatPane() throws {
        let view = try makeView()
        XCTAssertTrue(view.visibleCardTitlesForTesting.contains(englishCopy(.shellSection)))

        view.clickNavRowForTesting(.window)

        XCTAssertEqual(view.visibleCardTitlesForTesting, [englishCopy(.windowSizeSection)])
        XCTAssertFalse(view.visibleCardTitlesForTesting.contains(englishCopy(.shellSection)))
    }

    /// A query that lands in another pane moves the nav selection with it, so
    /// the nav never disagrees with the content beside it.
    func testACrossPaneQueryMovesTheNavSelectionToo() throws {
        let view = try makeView()

        view.applySearchQueryForTesting(englishCopy(.height))

        XCTAssertEqual(view.selectedCategoryForTesting, .window)
        XCTAssertEqual(view.selectedNavTitlesForTesting, [englishCopy(.windowCategory)])
    }

    // MARK: - Elastic content column

    /// The whole point of re-hosting: cards take the width the tab gives them
    /// instead of the 720pt window they were designed in.
    func testCardsFillTheContentColumnInANarrowSurface() throws {
        // Comfortably above the surface's own minimum — a row's label column
        // plus its control are fixed — and comfortably below the ceiling.
        let view = try makeView(width: 800)

        let cardWidth = try XCTUnwrap(view.visibleCardWidthsForTesting.first)
        XCTAssertLessThan(cardWidth, DesignTokens.Component.preferencesContentMaxWidthPX)
        XCTAssertEqual(
            cardWidth,
            view.detailAreaWidthForTesting - PreferencesView.Layout.outerInsetPX * 2,
            accuracy: 1,
            "a card must fill whatever the detail area has, minus its insets"
        )
    }

    /// Growing the surface has to reach the cards. A fixed-width card would
    /// leave the extra width as an empty gutter, which is the old window's
    /// failure mode carried into a tab.
    func testWideningTheSurfaceWidensTheCards() throws {
        let narrow = try makeView(width: 800)
        let wider = try makeView(width: 900)

        let narrowCard = try XCTUnwrap(narrow.visibleCardWidthsForTesting.first)
        let widerCard = try XCTUnwrap(wider.visibleCardWidthsForTesting.first)

        XCTAssertEqual(widerCard - narrowCard, 100, accuracy: 1)
    }

    /// And stop growing at the ceiling: past it a right-aligned label and its
    /// control drift so far apart the pair stops reading as one row.
    func testCardsStopAtTheContentColumnMaximumInAWideSurface() throws {
        let view = try makeView(width: 2200)

        let cardWidth = try XCTUnwrap(view.visibleCardWidthsForTesting.first)
        XCTAssertEqual(
            cardWidth,
            DesignTokens.Component.preferencesContentMaxWidthPX,
            accuracy: 1
        )
    }

    /// Every card in a pane shares the column, so their left and right edges
    /// line up down the page.
    func testEveryCardInAPaneIsTheSameWidth() throws {
        let view = try makeView(width: 1400)

        let widths = Set(view.visibleCardWidthsForTesting.map { Int($0.rounded()) })
        XCTAssertGreaterThan(view.visibleCardWidthsForTesting.count, 1)
        XCTAssertEqual(widths.count, 1, "cards must not each pick their own width")
    }

    // MARK: - Helpers

    private func englishCopy(_ key: PreferencesCopy.Key) -> String {
        PreferencesCopy.string(key, language: .english)
    }

    private func makeView(width: CGFloat = DesignTokens.Component.preferencesWidthPX) throws -> PreferencesView {
        AppLocalization.preference = .english
        let store = AppSettingsStore(
            settingsURL: temporaryDirectory
                .appendingPathComponent("settings-\(UUID().uuidString).json")
        )
        try store.save(.default)
        let frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: DesignTokens.Component.preferencesHeightPX
        )
        let view = PreferencesView(frame: frame, store: store)
        // Hosted in a window, and laid out, because the width assertions read
        // real geometry: nothing on this surface has a frame of its own until
        // the layout pass has run.
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return view
    }
}

/// The theme preview's two long-standing lies: it built colors in a calibrated
/// space the renderer never uses, and it drew in a fixed font, so changing the
/// terminal font previewed as nothing at all.
@MainActor
final class PreferencesThemePreviewTests: XCTestCase {
    private func makePreview() -> PreferencesThemePreviewView {
        PreferencesThemePreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 176))
    }

    // MARK: - Color parsing

    /// The renderer submits the palette to Metal as raw sRGB. A preview that
    /// parses the same hex into any other space shows the user a color their
    /// terminal will never draw.
    func testAPaletteHexParsesToItsExactSRGBComponents() throws {
        let preview = makePreview()

        let color = try XCTUnwrap(preview.colorForTesting("#5B9DFF").usingColorSpace(.sRGB))

        XCTAssertEqual(color.redComponent, 0x5B / 255, accuracy: 0.0001)
        XCTAssertEqual(color.greenComponent, 0x9D / 255, accuracy: 0.0001)
        XCTAssertEqual(color.blueComponent, 0xFF / 255, accuracy: 0.0001)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.0001)
    }

    /// The regression itself: the calibrated constructor this used to call
    /// produces measurably different sRGB components for the same hex.
    func testTheCalibratedConstructorItUsedToCallProducesADifferentColor() throws {
        let preview = makePreview()
        let calibrated = try XCTUnwrap(
            NSColor(
                calibratedRed: 0x5B / 255,
                green: 0x9D / 255,
                blue: 0xFF / 255,
                alpha: 1
            ).usingColorSpace(.sRGB)
        )
        let parsed = try XCTUnwrap(preview.colorForTesting("#5B9DFF").usingColorSpace(.sRGB))

        XCTAssertGreaterThan(
            abs(calibrated.redComponent - parsed.redComponent)
                + abs(calibrated.greenComponent - parsed.greenComponent)
                + abs(calibrated.blueComponent - parsed.blueComponent),
            0.01,
            "if these agreed there would have been no bug to fix"
        )
    }

    func testAPaletteHexAgreesWithTheParserTheRendererUses() throws {
        let hex = "#22252B"
        let preview = makePreview()
        let rendererComponents = try XCTUnwrap(ColorHexParser.components(hex))

        let color = try XCTUnwrap(preview.colorForTesting(hex).usingColorSpace(.sRGB))

        XCTAssertEqual(color.redComponent, CGFloat(rendererComponents.x), accuracy: 0.0001)
        XCTAssertEqual(color.greenComponent, CGFloat(rendererComponents.y), accuracy: 0.0001)
        XCTAssertEqual(color.blueComponent, CGFloat(rendererComponents.z), accuracy: 0.0001)
    }

    func testAMalformedHexFallsBackInsteadOfDrawingBlack() {
        let preview = makePreview()

        XCTAssertEqual(preview.colorForTesting("not-a-color", fallback: .yellow), .yellow)
        XCTAssertEqual(preview.colorForTesting("#12345", fallback: .yellow), .yellow)
        XCTAssertEqual(preview.colorForTesting("", fallback: .yellow), .yellow)
    }

    /// A settings edit writes the palette back as hex, so the color a well
    /// carries has to survive the round trip unchanged.
    func testAPaletteHexSurvivesTheRoundTripThroughAColorValue() {
        for hex in ["#5B9DFF", "#22252B", "#000000", "#FFFFFF", "#4ADE80"] {
            let color = NSColor.terminalPaletteSRGB(hex)
            XCTAssertEqual(color?.terminalPaletteHex, hex)
        }
    }

    // MARK: - Font

    func testThePreviewDrawsInTheConfiguredFamilyAndSize() {
        let preview = makePreview()

        preview.fontName = "Menlo"
        preview.fontSizePT = 20

        XCTAssertEqual(preview.bodyFontForTesting.familyName, "Menlo")
        XCTAssertEqual(preview.bodyFontForTesting.pointSize, 20)
    }

    /// The defect as the user met it: change the font size and the sample did
    /// not move, because it was pinned to 13pt SF Mono.
    func testChangingTheConfiguredSizeChangesThePreviewFont() {
        let preview = makePreview()
        preview.fontName = "Menlo"
        preview.fontSizePT = 12
        let before = preview.bodyFontForTesting.pointSize

        preview.fontSizePT = 18

        XCTAssertEqual(before, 12)
        XCTAssertEqual(preview.bodyFontForTesting.pointSize, 18)
    }

    /// A family the Mac does not have falls back the way the terminal does,
    /// rather than leaving the preview blank or claiming a font nothing can
    /// render.
    func testAnUninstalledFamilyFallsBackToAMonospacedSystemFontAtTheSameSize() {
        let preview = makePreview()

        preview.fontName = "Definitely Not An Installed Family"
        preview.fontSizePT = 17

        XCTAssertEqual(preview.bodyFontForTesting.pointSize, 17)
        XCTAssertEqual(
            preview.bodyFontForTesting.fontName,
            NSFont.monospacedSystemFont(ofSize: 17, weight: .regular).fontName
        )
    }

    /// Row pitch is derived from the point size, so a large terminal font does
    /// not draw the sample lines on top of each other.
    func testRowPitchGrowsWithTheFont() {
        let small = PreferencesThemePreviewFont.font(named: "Menlo", sizePT: 11, weight: .regular)
        let large = PreferencesThemePreviewFont.font(named: "Menlo", sizePT: 22, weight: .regular)

        XCTAssertGreaterThan(
            PreferencesThemePreviewFont.lineHeightPX(for: large),
            PreferencesThemePreviewFont.lineHeightPX(for: small)
        )
        XCTAssertGreaterThan(
            PreferencesThemePreviewFont.lineHeightPX(for: small),
            small.pointSize,
            "a row has to be taller than the glyphs in it"
        )
    }

    /// The surface keeps the preview in step with the settings it is editing.
    func testTheSurfaceFeedsThePreviewTheConfiguredFont() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-preview-font-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettingsStore(settingsURL: directory.appendingPathComponent("settings.json"))
        var settings = AppSettings.default
        settings.terminal.fontName = "Menlo"
        settings.terminal.fontSize = 18
        try store.save(settings)

        let view = PreferencesView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: DesignTokens.Component.preferencesWidthPX,
                height: DesignTokens.Component.preferencesHeightPX
            ),
            store: store
        )

        XCTAssertEqual(view.previewView.fontName, "Menlo")
        XCTAssertEqual(view.previewView.fontSizePT, 18)
    }
}
