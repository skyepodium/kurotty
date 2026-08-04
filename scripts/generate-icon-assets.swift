#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasSize = NSSize(width: 1024, height: 1024)
// AppKit uses a bottom-left origin; y=100 produces the required top-left
// alpha bounds of (99, 99, 924, 924) on the 1024 px PNG canvas.
private let tileRect = NSRect(x: 99, y: 100, width: 825, height: 825)
private let tileCornerRadius: CGFloat = 180

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("icon generation failed: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: generate-icon-assets.swift <source.png> <root-output.png> <resource-output.png>")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURLs = CommandLine.arguments.dropFirst(2).map(URL.init(fileURLWithPath:))

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fail("unable to load source image at \(sourceURL.path)")
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("unable to create RGBA canvas")
}

bitmap.size = canvasSize

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fail("unable to create drawing context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

NSBezierPath(
    roundedRect: tileRect,
    xRadius: tileCornerRadius,
    yRadius: tileCornerRadius
).addClip()

sourceImage.draw(
    in: tileRect,
    from: NSRect(origin: .zero, size: sourceImage.size),
    operation: .copy,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fail("unable to encode PNG")
}

for outputURL in outputURLs {
    do {
        try pngData.write(to: outputURL, options: .atomic)
    } catch {
        fail("unable to write \(outputURL.path): \(error)")
    }
}
