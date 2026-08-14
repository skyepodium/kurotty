import CoreGraphics
import Foundation
import XCTest
@testable import KurottyApp

/// The inline-image protocol, its store, and the arithmetic that turns a
/// declared size into cells.
///
/// All three are pure, so none of this needs a terminal, a screen or a web
/// view. What it does need is real payloads: the strings here are the shapes a
/// shell actually emits, including the ones that are *not* images.
final class TerminalInlineImageTests: XCTestCase {
    private enum Fixture {
        /// A one-pixel PNG, base64, as a program would send it.
        static let pngBase64 = """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """
        static let bounds = TerminalInlineImageLayout.Bounds(
            columns: 80, rows: 24, cellWidthPX: 8, cellHeightPX: 16
        )
    }

    private func payload(_ arguments: String) -> String {
        "File=\(arguments):\(Fixture.pngBase64)"
    }

    // MARK: - Parsing

    func testAnInlineImageIsRecognisedAndItsBytesDecoded() throws {
        let image = try XCTUnwrap(TerminalInlineImagePayload.parse(payload(";inline=1;width=40")))

        XCTAssertEqual(image.width, .cells(40))
        XCTAssertEqual(image.height, .auto)
        XCTAssertTrue(image.preservesAspectRatio)
        XCTAssertFalse(image.data.isEmpty)
        XCTAssertEqual(image.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "the PNG signature must survive")
    }

    /// Without `inline=1` the sender is asking for a *download*, which is a
    /// different feature. Drawing it would put a program's bytes on screen
    /// under an instruction that never asked for that.
    func testAFileTransferIsNotAnInlineImage() {
        XCTAssertNil(TerminalInlineImagePayload.parse(payload(";size=1234")))
    }

    /// The same OSC 1337 carries iTerm2's notifications, so a payload that is
    /// not an image is an ordinary outcome and the caller falls through to
    /// whatever else claims it.
    func testANotificationPayloadIsNotMistakenForAnImage() {
        XCTAssertNil(TerminalInlineImagePayload.parse("RemoteHost=user@host"))
        XCTAssertNil(TerminalInlineImagePayload.parse("CurrentDir=/tmp"))
    }

    func testEveryExtentSpellingIsUnderstood() throws {
        let cases: [(String, TerminalInlineImagePayload.Extent)] = [
            ("auto", .auto),
            ("12", .cells(12)),
            ("300px", .pixels(300)),
            ("50%", .percent(50)),
        ]
        for (spelling, expected) in cases {
            let image = try XCTUnwrap(TerminalInlineImagePayload.parse(payload(";inline=1;width=\(spelling)")))
            XCTAssertEqual(image.width, expected, "width=\(spelling)")
        }
    }

    /// A declared size is a request from an arbitrary program. `width=99999` is
    /// a request to lay out a hundred thousand columns, and the layout should
    /// never see a number it has to defend against.
    func testAnAbsurdExtentIsClampedAtTheProtocolEdge() throws {
        let image = try XCTUnwrap(TerminalInlineImagePayload.parse(payload(";inline=1;width=99999;height=999999px")))

        XCTAssertEqual(image.width, .cells(1_000))
        XCTAssertEqual(image.height, .pixels(20_000))
    }

    func testTheSendersFileNameSurvivesInEitherSpelling() throws {
        let encoded = Data("chart.png".utf8).base64EncodedString()

        // The older spelling puts the name in `File`'s own value.
        let named = try XCTUnwrap(
            TerminalInlineImagePayload.parse("File=\(encoded);inline=1:\(Fixture.pngBase64)")
        )
        XCTAssertEqual(named.name, "chart.png")

        let keyed = try XCTUnwrap(TerminalInlineImagePayload.parse(payload(";inline=1;name=\(encoded)")))
        XCTAssertEqual(keyed.name, "chart.png")
    }

    func testAPayloadWhoseBytesAreNotBase64IsRefused() {
        XCTAssertNil(TerminalInlineImagePayload.parse("File=;inline=1:not base64 at all !!!"))
        XCTAssertNil(TerminalInlineImagePayload.parse("File=;inline=1:"))
    }

    // MARK: - The store

    func testAnImageIsHeldOnceAndFoundByItsIdentifier() throws {
        let store = TerminalImageStore()
        let data = Data(repeating: 0xAB, count: 1024)

        let identifier = try XCTUnwrap(store.store(data: data, name: "chart.png"))
        let entry = try XCTUnwrap(store.entry(identifier))

        XCTAssertEqual(entry.data, data)
        XCTAssertEqual(entry.name, "chart.png")
        XCTAssertEqual(store.byteCount, data.count)
    }

    /// `cat *.png` is one keystroke, so a program can put images on screen
    /// faster than a person can scroll them off. The store drops the oldest
    /// once it is over its total, which is what scrollback does to rows.
    func testTheStoreDropsTheOldestImagesRatherThanGrowingWithoutBound() {
        let store = TerminalImageStore()
        let chunk = Data(repeating: 0, count: 8 * 1024 * 1024)
        var identifiers: [TerminalImageStore.Identifier] = []

        for _ in 0..<12 {
            if let identifier = store.store(data: chunk, name: nil) {
                identifiers.append(identifier)
            }
        }

        XCTAssertLessThanOrEqual(store.byteCount, 64 * 1024 * 1024)
        XCTAssertGreaterThan(store.evictionCount, 0, "twelve eight-megabyte images must not all fit")
        XCTAssertNil(store.entry(identifiers[0]), "the oldest image goes first")
        XCTAssertNotNil(store.entry(identifiers[identifiers.count - 1]), "the newest must survive")
    }

    /// An image bigger than the whole budget is refused rather than admitted
    /// and immediately evicted, which would clear the store of everything else
    /// on the way past.
    func testAnImageLargerThanTheBudgetIsRefusedWithoutClearingTheStore() throws {
        let store = TerminalImageStore()
        let kept = try XCTUnwrap(store.store(data: Data(repeating: 1, count: 4096), name: nil))

        XCTAssertNil(store.store(data: Data(repeating: 2, count: 65 * 1024 * 1024), name: nil))
        XCTAssertNotNil(store.entry(kept))
    }

    func testDiscardingAnImageReturnsItsBytes() throws {
        let store = TerminalImageStore()
        let identifier = try XCTUnwrap(store.store(data: Data(repeating: 3, count: 2048), name: nil))

        store.discard(identifier)

        XCTAssertNil(store.entry(identifier))
        XCTAssertEqual(store.byteCount, 0)
    }

    // MARK: - Layout

    private func layout(
        _ arguments: String,
        pixelSize: CGSize
    ) throws -> TerminalInlineImageLayout.Size {
        let image = try XCTUnwrap(TerminalInlineImagePayload.parse(payload(";inline=1;\(arguments)")))
        return TerminalInlineImageLayout.size(for: image, pixelSize: pixelSize, in: Fixture.bounds)
    }

    func testAnImageWithNoRequestTakesItsOwnPixelsInCells() throws {
        let size = try layout("", pixelSize: CGSize(width: 160, height: 160))

        XCTAssertEqual(size, .init(columns: 20, rows: 10))
    }

    /// The common case, and the one where guessing the other dimension is the
    /// whole job.
    func testOneExtentGivenLetsTheImageKeepItsProportions() throws {
        let size = try layout("width=40", pixelSize: CGSize(width: 400, height: 200))

        // 400x200 pixels is 50x12.5 cells, a ratio of 4:1 in cells. Forty
        // columns therefore wants ten rows.
        XCTAssertEqual(size, .init(columns: 40, rows: 10))
    }

    /// A ratio applied in pixels comes out squashed, because a cell is twice as
    /// tall as it is wide. A square image must come out square on screen.
    func testTheRatioIsMeasuredInCellsRatherThanPixels() throws {
        let size = try layout("width=20", pixelSize: CGSize(width: 200, height: 200))

        // 200x200 is 25x12.5 cells, so twenty columns is ten rows — half the
        // count, which is what square looks like on a grid of 8x16 cells.
        XCTAssertEqual(size, .init(columns: 20, rows: 10))
    }

    func testBothExtentsGivenFitsInsideTheBoxRatherThanStretching() throws {
        let size = try layout("width=40;height=40", pixelSize: CGSize(width: 400, height: 200))

        XCTAssertEqual(size, .init(columns: 40, rows: 10), "the image fits the box it was given")
    }

    /// `preserveAspectRatio=0` is how a program says it means to stretch.
    ///
    /// Twenty rows rather than forty, because forty is past the screen and the
    /// clamp would answer for the stretch — the point here is that the ratio
    /// was ignored, so the request has to be one the terminal can grant.
    func testASenderMayStretchWhenItSaysSo() throws {
        let size = try layout("width=40;height=20;preserveAspectRatio=0", pixelSize: CGSize(width: 400, height: 200))

        XCTAssertEqual(size, .init(columns: 40, rows: 20))
    }

    func testAPercentageIsTakenAgainstTheTerminalRatherThanTheImage() throws {
        let size = try layout("width=50%;height=50%;preserveAspectRatio=0", pixelSize: CGSize(width: 10, height: 10))

        XCTAssertEqual(size, .init(columns: 40, rows: 12))
    }

    /// An image resolved to zero rows would advance the cursor by nothing and
    /// be overwritten by the next line before anyone saw it, which reads as the
    /// terminal having dropped it.
    func testAnImageNeverResolvesToNothing() throws {
        let size = try layout("", pixelSize: CGSize(width: 1, height: 1))

        XCTAssertEqual(size, .init(columns: 1, rows: 1))
    }

    func testAnImageNeverExceedsTheTerminalItIsDrawnIn() throws {
        let size = try layout("width=500;height=500;preserveAspectRatio=0", pixelSize: CGSize(width: 10, height: 10))

        XCTAssertEqual(size, .init(columns: 80, rows: 24))
    }
}

/// The glyph a session wears, derived from where it is running.
final class TerminalSessionGlyphTests: XCTestCase {
    private func location(_ remoteHost: String?) -> TerminalWorkingDirectoryLocation {
        TerminalWorkingDirectoryLocation(path: "/tmp", remoteHost: remoteHost)
    }

    /// Marking the ordinary case teaches the eye to ignore the mark, which is
    /// exactly what must not happen to the warning below.
    func testALocalShellWearsNothing() {
        XCTAssertNil(TerminalSessionGlyph.glyph(for: location(nil)))
    }

    /// The one case that must never be missed, and the one that does not
    /// depend on a hash: a warning that varies by host is not a warning.
    func testARootShellAlwaysWearsTheSameWarning() {
        XCTAssertEqual(TerminalSessionGlyph.glyph(for: location("root@prod-1")), TerminalSessionGlyph.root)
        XCTAssertEqual(TerminalSessionGlyph.glyph(for: location("root@staging")), TerminalSessionGlyph.root)
    }

    func testAnOrdinaryRemoteShellDoesNotWearTheWarning() {
        XCTAssertNotEqual(TerminalSessionGlyph.glyph(for: location("deploy@prod-1")), TerminalSessionGlyph.root)
        XCTAssertNotNil(TerminalSessionGlyph.glyph(for: location("deploy@prod-1")))
    }

    /// The whole point is that two windows on the same host look alike. A
    /// per-process hash seed would give the same box a different glyph in every
    /// window and a different one again after a restart.
    func testTheSameHostAlwaysWearsTheSameGlyph() {
        let first = TerminalSessionGlyph.glyph(for: location("deploy@prod-1"))
        let again = TerminalSessionGlyph.glyph(for: location("deploy@prod-1"))

        XCTAssertEqual(first, again)
        XCTAssertEqual(first, TerminalSessionGlyph.glyph(for: location("someone-else@prod-1")))
    }

    func testDifferentHostsGetDifferentGlyphsMostOfTheTime() {
        let hosts = (1...16).map { "deploy@host-\($0)" }
        let glyphs = Set(hosts.compactMap { TerminalSessionGlyph.glyph(for: location($0)) })

        XCTAssertGreaterThanOrEqual(glyphs.count, 8, "sixteen hosts collapsed to \(glyphs.count) glyphs")
    }
}
