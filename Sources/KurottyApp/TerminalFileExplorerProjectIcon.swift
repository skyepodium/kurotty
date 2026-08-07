import AppKit

/// Orca-style identity image for a directory shown directly under the
/// explorer root. Nested folders keep the semantic folder glyph; only project
/// rows spend their leading slot on branding.
enum FileExplorerProjectIconSource: Hashable, Sendable {
    case localFile(URL)
    case generated(String)
}

enum FileExplorerProjectIconResolver {
    private static let maxLocalImageBytes = 256 * 1024
    private static let projectMarkerPaths = [
        ".git", "package.json", "Package.swift", "build.zig", "Cargo.toml",
        "pyproject.toml", "go.mod",
    ]

    /// Same deliberately short conventional-path probe used by Orca. Raster
    /// images only: decoding an SVG on every outline repaint is not a sidebar
    /// responsibility.
    static let localCandidates = [
        "favicon.png", "favicon.webp",
        "public/favicon.png", "public/favicon.webp",
        "app/favicon.png", "app/favicon.webp",
        "app/icon.png", "app/icon.webp",
        "src/favicon.png", "src/favicon.webp",
        "src/app/icon.png", "src/app/icon.webp",
        "assets/favicon.png", "assets/favicon.webp",
        "assets/icon.png", "assets/icon.webp",
        "static/favicon.png", "static/favicon.webp",
        "logo.png", "logo.webp",
        "public/logo.png", "public/logo.webp",
        "public/icon.png", "public/icon.webp",
        "src-tauri/icons/icon.png", "src-tauri/icons/icon.webp",
        "app-icon.png", "app-icon.webp",
        "icon.png", "icon.webp",
    ]

    static func source(
        for projectDirectory: URL,
        fileManager: FileManager = .default
    ) -> FileExplorerProjectIconSource? {
        let root = projectDirectory.standardizedFileURL
        if let localURL = localCandidates.lazy
            .map({ root.appendingPathComponent($0).standardizedFileURL })
            .first(where: { isSupportedLocalIcon($0, fileManager: fileManager) }) {
            return .localFile(localURL)
        }
        let isProject = projectMarkerPaths.contains { relativePath in
            fileManager.fileExists(atPath: root.appendingPathComponent(relativePath).path)
        }
        return isProject ? .generated(root.lastPathComponent) : nil
    }

    static func sources(
        for projectDirectories: [URL]
    ) async -> [(URL, FileExplorerProjectIconSource?)] {
        var resolved: [(URL, FileExplorerProjectIconSource?)] = []
        resolved.reserveCapacity(projectDirectories.count)
        for url in projectDirectories {
            guard !Task.isCancelled else { break }
            resolved.append((url, source(for: url)))
        }
        return resolved
    }

    private static func isBoundedFile(
        _ url: URL,
        maxBytes: Int,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue <= maxBytes
    }

    private static func isSupportedLocalIcon(_ url: URL, fileManager: FileManager) -> Bool {
        guard isBoundedFile(url, maxBytes: maxLocalImageBytes, fileManager: fileManager),
              let data = try? Data(contentsOf: url),
              data.count >= 12
        else {
            return false
        }
        let bytes = [UInt8](data.prefix(12))
        let isPNG = bytes.prefix(8) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        let isWebP = Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46]
            && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
        return isPNG || isWebP
    }
}

@MainActor
final class FileExplorerProjectIconLoader {
    static let shared = FileExplorerProjectIconLoader()

    private var imageCache: [FileExplorerProjectIconSource: NSImage] = [:]
    private var failedSources: Set<FileExplorerProjectIconSource> = []

    func invalidate() {
        imageCache.removeAll()
        failedSources.removeAll()
    }

    func load(
        _ source: FileExplorerProjectIconSource,
        completion: @escaping (NSImage?) -> Void
    ) {
        if let cached = imageCache[source] {
            completion(cached)
            return
        }
        guard !failedSources.contains(source) else {
            completion(nil)
            return
        }
        switch source {
        case .localFile(let url):
            let image = NSImage(contentsOf: url).map(Self.sidebarImage)
            if let image {
                imageCache[source] = image
            } else {
                failedSources.insert(source)
            }
            completion(image)
        case .generated(let label):
            let image = Self.generatedImage(label: label)
            imageCache[source] = image
            completion(image)
        }
    }

    private static func generatedImage(label: String) -> NSImage {
        let side = DesignTokens.Component.fileExplorerProjectIconSizePX
        let result = NSImage(size: NSSize(width: side, height: side))
        result.lockFocus()
        defer { result.unlockFocus() }

        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        avatarColor(for: label).setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: DesignTokens.Component.fileExplorerProjectIconCornerRadiusPX,
            yRadius: DesignTokens.Component.fileExplorerProjectIconCornerRadiusPX
        ).fill()
        let initial = label.first.map { String($0).uppercased() } ?? "•"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(9, side * 0.58), weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = initial.size(withAttributes: attributes)
        initial.draw(
            at: NSPoint(
                x: (side - textSize.width) / 2,
                y: (side - textSize.height) / 2
            ),
            withAttributes: attributes
        )
        result.isTemplate = false
        return result
    }

    private static func avatarColor(for label: String) -> NSColor {
        let palette: [NSColor] = [
            NSColor(red: 0.33, green: 0.43, blue: 0.72, alpha: 1),
            NSColor(red: 0.60, green: 0.34, blue: 0.55, alpha: 1),
            NSColor(red: 0.25, green: 0.52, blue: 0.55, alpha: 1),
            NSColor(red: 0.58, green: 0.39, blue: 0.31, alpha: 1),
            NSColor(red: 0.34, green: 0.50, blue: 0.37, alpha: 1),
            NSColor(red: 0.55, green: 0.45, blue: 0.25, alpha: 1),
        ]
        let hash = label.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private static func sidebarImage(_ source: NSImage) -> NSImage {
        let side = DesignTokens.Component.fileExplorerProjectIconSizePX
        let result = NSImage(size: NSSize(width: side, height: side))
        result.lockFocus()
        defer { result.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        NSBezierPath(
            roundedRect: bounds,
            xRadius: DesignTokens.Component.fileExplorerProjectIconCornerRadiusPX,
            yRadius: DesignTokens.Component.fileExplorerProjectIconCornerRadiusPX
        ).addClip()
        let sourceSize = source.size
        let scale = sourceSize.width > 0 && sourceSize.height > 0
            ? min(side / sourceSize.width, side / sourceSize.height)
            : 1
        let drawSize = NSSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let drawRect = NSRect(
            x: (side - drawSize.width) / 2,
            y: (side - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        source.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        result.isTemplate = false
        return result
    }
}
