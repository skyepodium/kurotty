import AppKit
import XCTest

/// The DMG install window is built from two halves that can never see each
/// other: `scripts/generate-dmg-background.swift` bakes the headline and the
/// chevrons into a picture, and `scripts/dmg-style.sh` tells Finder where to drop
/// the two icons on top of it. Nothing at runtime catches a disagreement — the
/// DMG just opens looking wrong — so the agreement is measured here out of what
/// both halves actually produce.
///
/// The other thing worth guarding is the CI failure mode. Driving Finder over
/// AppleScript can block forever on a GitHub Actions runner, and a release
/// workflow that hangs is worse than an unstyled DMG, so the timeout and the
/// skip switch are exercised rather than trusted.
final class DMGInstallWindowTests: XCTestCase {
    private static let windowSize = NSSize(width: 800, height: 400)

    /// Rendering shells out to a `swift` script twice, which is slow enough that
    /// every image assertion in this file shares one render.
    private static let renderedVolumeRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-dmg-window-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = runBash(
            """
            set -eo pipefail
            source scripts/dmg-style.sh
            render_kurotty_dmg_background "$PWD/scripts" '\(root.path)' >/dev/null
            printf '%s %s %s %s %s %s' \
              "$KUROTTY_DMG_APP_ICON_Y" \
              "$KUROTTY_DMG_APPLICATIONS_ICON_Y" \
              "$KUROTTY_DMG_ICON_SIZE" \
              "$KUROTTY_DMG_BACKGROUND_HEIGHT" \
              "$KUROTTY_DMG_WINDOW_HEIGHT" \
              "$KUROTTY_DMG_BACKGROUND_FILE"
            """
        )
        precondition(result.status == 0, "render_kurotty_dmg_background failed: \(result.output)")
        renderedGeometry = result.output
        return root
    }()

    nonisolated(unsafe) private static var renderedGeometry = ""

    override class func tearDown() {
        try? FileManager.default.removeItem(at: renderedVolumeRoot)
        super.tearDown()
    }

    @discardableResult
    private static func runBash(_ script: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try! process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func background(_ name: String) throws -> PixelGrid {
        let url = Self.renderedVolumeRoot
            .appendingPathComponent(".background")
            .appendingPathComponent(name)
        return try PixelGrid(contentsOf: url)
    }

    private struct Geometry {
        let iconRowY: Int
        let iconSize: Int
        let backgroundHeight: Int
        let windowHeight: Int
        let backgroundFile: String
    }

    private func geometry() throws -> Geometry {
        let fields = Self.renderedGeometry.split(separator: " ").map(String.init)
        XCTAssertEqual(fields.count, 6, Self.renderedGeometry)
        XCTAssertEqual(fields[0], fields[1], "both icons must sit on one row")
        return Geometry(
            iconRowY: try XCTUnwrap(Int(fields[0])),
            iconSize: try XCTUnwrap(Int(fields[2])),
            backgroundHeight: try XCTUnwrap(Int(fields[3])),
            windowHeight: try XCTUnwrap(Int(fields[4])),
            backgroundFile: fields[5]
        )
    }

    func testBothRenditionsDescribeTheSameEightHundredByFourHundredWindow() throws {
        let oneX = try background("background.png")
        let twoX = try background("background@2x.png")

        XCTAssertEqual(oneX.pixelWidth, 800)
        XCTAssertEqual(oneX.pixelHeight, 400)
        XCTAssertEqual(twoX.pixelWidth, 1600)
        XCTAssertEqual(twoX.pixelHeight, 800)

        // The @2x file only lays out correctly because it is stamped at 144 dpi.
        // Without that, AppKit would hand Finder a 1600x800 point image and the
        // window would show the top-left quarter of the design.
        XCTAssertEqual(oneX.pointSize, Self.windowSize)
        XCTAssertEqual(twoX.pointSize, Self.windowSize)
    }

    func testTheBackgroundIsNotBlank() throws {
        let image = try background("background@2x.png")

        // The gradient has to actually run warm-to-cool across the window, which
        // is what makes the ground point the same way as the drag.
        let left = image.rgb(x: 4, y: image.pixelHeight / 2)
        let right = image.rgb(x: image.pixelWidth - 5, y: image.pixelHeight / 2)
        XCTAssertGreaterThan(left.red - left.blue, 0.01, "left edge should be warm neutral")
        XCTAssertGreaterThan(right.blue - right.red, 0.01, "right edge should be an accent wash")

        // And the copy block above the icon row has to hold dark ink rather than
        // more gradient. The renderer itself refuses to emit a picture whose text
        // fell back to .notdef, so reaching this assertion also means the Korean
        // lines found a font with the glyphs.
        var darkest = 1.0
        for y in 0..<(image.pixelHeight / 2) {
            for x in stride(from: 0, to: image.pixelWidth, by: 2) {
                darkest = min(darkest, image.rgb(x: x, y: y).luminance)
            }
        }
        XCTAssertLessThan(darkest, 0.3, "instruction copy should be dark ink, not an empty band")
    }

    /// The chevrons are painted into the picture; the icons are placed by Finder.
    /// The only thing keeping them on one line is that both halves read the same
    /// number, so measure the chevrons and compare against what the shell sends.
    func testTheBakedChevronsSitOnTheIconRowFinderIsToldToUse() throws {
        let geometry = try geometry()
        let image = try background("background.png")

        // The chevrons are the only saturated blue in the picture, so their
        // vertical centroid is the row they were drawn on.
        var weightedRows = 0
        var samples = 0
        for y in 0..<image.pixelHeight {
            for x in 0..<image.pixelWidth where image.rgb(x: x, y: y).isAccentBlue {
                weightedRows += y
                samples += 1
            }
        }
        XCTAssertGreaterThan(samples, 200, "chevrons should be present")
        XCTAssertEqual(Double(weightedRows) / Double(samples), Double(geometry.iconRowY), accuracy: 3)
    }

    /// Both halves of the overflow that made the window scroll once, since a
    /// scrolling install window can put the Applications folder below the fold.
    func testNothingInTheInstallRowFallsOffTheBottomOfTheWindow() throws {
        let geometry = try geometry()

        // Finder's `bounds` is the window frame, so the frame has to be taller
        // than the picture by the title bar or the content area comes up short
        // and Finder makes up the difference by scrolling.
        XCTAssertGreaterThan(
            geometry.windowHeight,
            geometry.backgroundHeight,
            "the window frame must allow for the title bar above the background"
        )
        XCTAssertEqual(geometry.backgroundHeight, Int(Self.windowSize.height))

        // The label Finder draws under each icon is outside the icon's frame, so
        // the row's real bottom is the icon bottom plus a line of text. Keep a
        // visible margin under that rather than landing on the edge.
        let labelAllowance = 22
        let bottomMargin = 24
        XCTAssertLessThanOrEqual(
            geometry.iconRowY + geometry.iconSize / 2 + labelAllowance + bottomMargin,
            geometry.backgroundHeight
        )
    }

    func testFinderIsGivenOneOfTheTwoRenditionsThatWereActuallyRendered() throws {
        let geometry = try geometry()
        XCTAssertTrue(
            ["background.tiff", "background@2x.png"].contains(geometry.backgroundFile),
            "Finder was pointed at \(geometry.backgroundFile)"
        )
        let url = Self.renderedVolumeRoot
            .appendingPathComponent(".background")
            .appendingPathComponent(geometry.backgroundFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
    }

    func testAHangingFinderIsCutOffInsteadOfBlockingTheRelease() {
        let started = Date()
        let result = Self.runBash(
            """
            source scripts/dmg-style.sh
            run_with_kurotty_dmg_timeout 2 sleep 60
            """
        )
        // 128 + SIGALRM(14). The alarm has to land on the process being bounded,
        // which is why the helper execs instead of spawning a child it would
        // leave running after the wrapper dies.
        XCTAssertEqual(result.status, 142)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testASkippedStylingPassDoesNotLookLikeAStyledDMG() {
        let result = Self.runBash(
            """
            source scripts/dmg-style.sh
            KUROTTY_SKIP_DMG_STYLING=1 style_kurotty_dmg_window /Volumes/NoSuchKurottyVolume
            """
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("KUROTTY_SKIP_DMG_STYLING"), result.output)
    }

    func testThePackagingScriptsParse() {
        for script in ["dmg-style.sh", "package-release.sh", "verify-release-artifact.sh"] {
            let result = Self.runBash("bash -n scripts/\(script)")
            XCTAssertEqual(result.status, 0, "\(script): \(result.output)")
        }
    }
}

/// Straight sRGB byte access. `NSBitmapImageRep.colorAt(x:y:)` is far too slow
/// to sweep an 800x400 image pixel by pixel.
private struct PixelGrid {
    struct Pixel {
        let red: Double
        let green: Double
        let blue: Double

        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
        /// True only for the accent stroke, not for the pale wash on the right
        /// half of the gradient.
        var isAccentBlue: Bool { blue - red > 0.12 }
    }

    let pixelWidth: Int
    let pixelHeight: Int
    let pointSize: NSSize
    private let bytes: [UInt8]

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        let image = try XCTUnwrap(rep.cgImage)
        let width = image.width
        let height = image.height

        var storage = [UInt8](repeating: 0, count: width * height * 4)
        storage.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        pixelWidth = width
        pixelHeight = height
        pointSize = rep.size
        bytes = storage
    }

    /// `y` is measured from the top, matching the window coordinates the design
    /// constants are written in.
    func rgb(x: Int, y: Int) -> Pixel {
        let offset = (y * pixelWidth + x) * 4
        return Pixel(
            red: Double(bytes[offset]) / 255,
            green: Double(bytes[offset + 1]) / 255,
            blue: Double(bytes[offset + 2]) / 255
        )
    }
}
