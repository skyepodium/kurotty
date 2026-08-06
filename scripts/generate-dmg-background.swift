#!/usr/bin/env swift

import AppKit
import Foundation

// The install window is the first Kurotty surface a user ever sees, so it is
// drawn from the app's own light ramp (Sources/KurottyApp/DesignTokens.swift,
// DesignTokens.Color.Light) instead of an installer palette invented here. The
// file is generated at package time for the same reason the icon assets are:
// the design stays reviewable as code and cannot drift from the tokens.
private let canvasSize = NSSize(width: 800, height: 400)

/// Warm-neutral paper, half a step below `Light.surfaceChrome` (#F4F4F2) toward
/// `Light.hairline` (#E9E9E5). The ramp is warm-neutral, so the ground is too.
private let paperLeft = 0xF1_EF_E8
/// `Light.surfaceCanvas`.
private let paperCenter = 0xFF_FF_FF
/// `Light.accent` (#1F63D6) at 8% over `surfaceCanvas`. The gradient runs warm
/// on the app side and cool-accent on the Applications side so the ground
/// itself points the same direction as the drag.
private let accentWash = 0xED_F2_FC
/// `Light.textPrimary`.
private let headlineInk = 0x1A_1A_18
/// `Light.textSecondary`.
private let reasonInk = 0x52_52_4D
/// `Light.accent`.
private let chevronInk = 0x1F_63_D6

/// One centred line of the copy stack.
private struct CopyLine {
    let text: String
    let size: CGFloat
    let weight: NSFont.Weight
    let ink: Int
    /// Space above this line, measured from the bottom of the previous one (or
    /// from the top of the window for the first).
    let leading: CGFloat
}

/// The window is a baked image: one DMG ships to every user, and there is no
/// per-language background in the format, so the copy cannot follow the system
/// language. It is Korean only, and deliberately: the icon, the chevrons and the
/// Applications folder already spell out *what to do* in a convention every macOS
/// user reads without words. An English instruction would only restate the
/// picture.
///
/// What the picture cannot say is *why*, and that is the second block: the DMG
/// mounts read-only, and Sparkle — which this app ships and starts at launch —
/// cannot update a bundle it has no write access to (see AppInstallLocation.swift).
/// That is the sentence that makes someone drag the icon rather than double-click
/// it where it sits.
///
/// Those two lines are one sentence, and the break is placed, not wrapped: the
/// cause has to land before the consequence, so the comma ends the first line.
private let copyLines: [CopyLine] = [
    CopyLine(
        text: "설치하려면 응용 프로그램 폴더로 옮겨주세요",
        size: 20,
        weight: .semibold,
        ink: headlineInk,
        leading: 34
    ),
    CopyLine(text: "이 디스크는 읽기 전용이라,", size: 15, weight: .regular, ink: reasonInk, leading: 14),
    CopyLine(text: "여기서 열면 스스로 업데이트할 수 없어요", size: 15, weight: .regular, ink: reasonInk, leading: 2),
]

/// Vertical centre of the icon row, measured from the top of the window. Finder
/// places `kurotty.app` and the `Applications` symlink on this same line, so the
/// chevrons have to sit on it too.
///
/// The row has to clear its own label: Finder draws the filename *below* the
/// icon, outside the icon's frame, so the real bottom of this row is
/// `iconRowCenterFromTop + iconSize / 2` plus a label. dmg-style.sh owns the icon
/// size and DMGInstallWindowTests asserts the two leave a bottom margin — a row
/// placed by the icon alone pushes its label off the window.
private let iconRowCenterFromTop: CGFloat = 240
private let chevronCount = 3
private let chevronSpacing: CGFloat = 27
private let chevronHalfWidth: CGFloat = 8
private let chevronHalfHeight: CGFloat = 15
private let chevronLineWidth: CGFloat = 5
/// Opacity rises left to right. The mark itself is a cat trailing speed lines;
/// the chevrons borrow that read so the row has a direction rather than three
/// identical arrows.
private let chevronAlphas: [CGFloat] = [0.28, 0.55, 0.90]

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dmg background generation failed: \(message)\n".utf8))
    exit(1)
}

private func srgb(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
    fail("usage: generate-dmg-background.swift <output.png> [scale]")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let scale = CommandLine.arguments.count == 3 ? (Double(CommandLine.arguments[2]) ?? 0) : 1
guard scale == 1 || scale == 2 else {
    fail("scale must be 1 or 2, got \(CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "1")")
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width * scale),
    pixelsHigh: Int(canvasSize.height * scale),
    bitsPerSample: 8,
    // RGBA even though the gradient covers the canvas: NSGraphicsContext refuses
    // to back a rep without an alpha channel.
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("unable to create RGBA canvas")
}

// Point size stays 800x400 whatever the scale. That both gives the drawing code
// one coordinate system and stamps the PNG with the matching DPI, which is how
// Finder learns that the @2x file is a Retina rendition and not a huge image.
bitmap.size = canvasSize

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fail("unable to create drawing context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true

let canvasRect = NSRect(origin: .zero, size: canvasSize)

guard let gradient = NSGradient(
    colorsAndLocations: (srgb(paperLeft), 0.0), (srgb(paperCenter), 0.5), (srgb(accentWash), 1.0)
) else {
    fail("unable to build background gradient")
}
gradient.draw(in: canvasRect, angle: 0)

// The system font carries no Hangul of its own; CoreText cascades to the Korean
// face at draw time. Missing glyphs would bake in as boxes, so every render is
// checked for a glyph the fallback could not supply.
var copyCursorFromTop: CGFloat = 0
for line in copyLines {
    let font = NSFont.systemFont(ofSize: line.size, weight: line.weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: srgb(line.ink),
    ]
    let attributed = NSAttributedString(string: line.text, attributes: attributes)

    let missing = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed))
    if let runs = missing as? [CTRun] {
        for run in runs {
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
            if glyphs.contains(0) {
                fail("no font on this machine covers \"\(line.text)\"")
            }
        }
    }

    let bounds = attributed.size()
    copyCursorFromTop += line.leading
    attributed.draw(
        at: NSPoint(
            x: (canvasSize.width - bounds.width) / 2,
            // AppKit's origin is bottom-left; the cursor is measured from the top.
            y: canvasSize.height - copyCursorFromTop - bounds.height
        )
    )
    copyCursorFromTop += bounds.height
}

let chevronCenterY = canvasSize.height - iconRowCenterFromTop
let chevronRowWidth = CGFloat(chevronCount - 1) * chevronSpacing
for index in 0..<chevronCount {
    let centerX = canvasSize.width / 2 - chevronRowWidth / 2 + CGFloat(index) * chevronSpacing
    let path = NSBezierPath()
    path.move(to: NSPoint(x: centerX - chevronHalfWidth, y: chevronCenterY + chevronHalfHeight))
    path.line(to: NSPoint(x: centerX + chevronHalfWidth, y: chevronCenterY))
    path.line(to: NSPoint(x: centerX - chevronHalfWidth, y: chevronCenterY - chevronHalfHeight))
    path.lineWidth = chevronLineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    srgb(chevronInk, alpha: chevronAlphas[index]).setStroke()
    path.stroke()
}

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fail("unable to encode PNG")
}

do {
    try pngData.write(to: outputURL, options: .atomic)
} catch {
    fail("unable to write \(outputURL.path): \(error)")
}
