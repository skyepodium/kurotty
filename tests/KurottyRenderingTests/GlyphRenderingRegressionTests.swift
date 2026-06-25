import AppKit
import CryptoKit
import XCTest

final class GlyphRenderingRegressionTests: XCTestCase {
    func testPromptGlyphSnapshotHash() throws {
        let width = 640
        let height = 96
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("failed to create bitmap context")
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
        ]
        ("skyepodium ~/dev/kurotty 하이" as NSString).draw(at: NSPoint(x: 8, y: 48), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let digest = SHA256.hash(data: Data(pixels))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(digest, "81cd14e8f75dfe52d74d533fd2ebbca411cccadfe78e65968748ce0f1119390d")
    }
}
