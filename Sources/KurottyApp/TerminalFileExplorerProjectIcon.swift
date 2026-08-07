import AppKit

/// Orca-style identity image for a directory shown directly under the
/// explorer root. Nested folders keep the semantic folder glyph; only project
/// rows spend their leading slot on branding.
enum FileExplorerProjectIconSource: Hashable, Sendable {
    case localFile(URL)
    case githubAvatar(owner: String, fallbackLabel: String)
    case generated(String)
}

enum FileExplorerProjectIconResolver {
    private static let maxLocalImageBytes = 256 * 1024
    private static let maxGitMetadataBytes = 512 * 1024
    static let maxRemoteImageBytes = 512 * 1024
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
        guard isProject else { return nil }
        if let owner = githubOwner(for: root, fileManager: fileManager) {
            return .githubAvatar(owner: owner, fallbackLabel: root.lastPathComponent)
        }
        return .generated(root.lastPathComponent)
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

    static func githubOwner(fromRemoteURL remoteURL: String) -> String? {
        let value = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let url = URL(string: value),
           let host = url.host?.lowercased(),
           host == "github.com" {
            path = url.path
        } else {
            guard let separator = value.firstIndex(of: ":") else { return nil }
            let authority = value[..<separator]
            let host = authority.split(separator: "@", omittingEmptySubsequences: false).last?
                .lowercased()
            guard host == "github.com" else { return nil }
            path = String(value[value.index(after: separator)...])
        }

        guard let owner = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .removingPercentEncoding,
            !owner.isEmpty,
            owner.count <= 39,
            owner.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else {
            return nil
        }
        return owner
    }

    private static func githubOwner(
        for projectDirectory: URL,
        fileManager: FileManager
    ) -> String? {
        var remotes: [String: String] = [:]
        for configURL in gitConfigURLs(for: projectDirectory, fileManager: fileManager) {
            guard let contents = boundedString(
                at: configURL,
                maxBytes: maxGitMetadataBytes,
                fileManager: fileManager
            ) else { continue }
            for (name, url) in remoteURLs(inGitConfig: contents) where remotes[name] == nil {
                remotes[name] = url
            }
        }
        for remoteName in ["upstream", "origin"] {
            if let remoteURL = remotes[remoteName],
               let owner = githubOwner(fromRemoteURL: remoteURL) {
                return owner
            }
        }
        return nil
    }

    private static func gitConfigURLs(
        for projectDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let dotGit = projectDirectory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return []
        }
        if isDirectory.boolValue {
            return [dotGit.appendingPathComponent("config")]
        }

        guard let pointer = boundedString(at: dotGit, maxBytes: 4 * 1024, fileManager: fileManager),
              let separator = pointer.firstIndex(of: ":"),
              pointer[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "gitdir"
        else {
            return []
        }
        let rawPath = pointer[pointer.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return [] }
        let gitDirectory = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            : projectDirectory.appendingPathComponent(rawPath, isDirectory: true).standardizedFileURL
        var configURLs = [gitDirectory.appendingPathComponent("config")]
        if let commonDirectory = boundedString(
            at: gitDirectory.appendingPathComponent("commondir"),
            maxBytes: 4 * 1024,
            fileManager: fileManager
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !commonDirectory.isEmpty {
            let commonURL = commonDirectory.hasPrefix("/")
                ? URL(fileURLWithPath: commonDirectory, isDirectory: true).standardizedFileURL
                : gitDirectory.appendingPathComponent(commonDirectory, isDirectory: true).standardizedFileURL
            configURLs.append(commonURL.appendingPathComponent("config"))
        }
        return configURLs
    }

    private static func remoteURLs(inGitConfig contents: String) -> [String: String] {
        var currentRemote: String?
        var remotes: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                currentRemote = nil
                let prefix = "[remote \""
                guard line.lowercased().hasPrefix(prefix), line.hasSuffix("\"]") else { continue }
                currentRemote = String(line.dropFirst(prefix.count).dropLast(2)).lowercased()
                continue
            }
            guard let currentRemote,
                  remotes[currentRemote] == nil,
                  let separator = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "url" else { continue }
            remotes[currentRemote] = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return remotes
    }

    private static func boundedString(
        at url: URL,
        maxBytes: Int,
        fileManager: FileManager
    ) -> String? {
        guard isBoundedFile(url, maxBytes: maxBytes, fileManager: fileManager),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return String(data: data, encoding: .utf8)
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
              let data = try? Data(contentsOf: url)
        else {
            return false
        }
        return isSupportedRasterImage(data)
    }

    static func isSupportedRasterImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(12))
        let isPNG = bytes.prefix(8) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        let isJPEG = bytes.prefix(3) == [0xff, 0xd8, 0xff]
        let isWebP = Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46]
            && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
        return isPNG || isJPEG || isWebP
    }
}

@MainActor
final class FileExplorerProjectIconLoader {
    static let shared = FileExplorerProjectIconLoader()

    typealias RemoteDataLoader = @Sendable (URL) async throws -> Data
    private static let remoteCacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    private struct PendingRemoteCompletion {
        let source: FileExplorerProjectIconSource
        let completion: (NSImage?) -> Void
    }

    private var imageCache: [FileExplorerProjectIconSource: NSImage] = [:]
    private var failedSources: Set<FileExplorerProjectIconSource> = []
    private var remoteTasks: [String: Task<Void, Never>] = [:]
    private var remoteCompletions: [String: [PendingRemoteCompletion]] = [:]
    private let cacheDirectory: URL
    private let remoteDataLoader: RemoteDataLoader

    init(
        cacheDirectory: URL? = nil,
        remoteDataLoader: RemoteDataLoader? = nil
    ) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Kurotty", isDirectory: true)
        .appendingPathComponent("project-icons", isDirectory: true)
        self.remoteDataLoader = remoteDataLoader ?? Self.fetchRemoteImage
    }

    func invalidate() {
        remoteTasks.values.forEach { $0.cancel() }
        remoteTasks.removeAll()
        remoteCompletions.removeAll()
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
            if case .githubAvatar(_, let fallbackLabel) = source {
                completion(Self.generatedImage(label: fallbackLabel))
            } else {
                completion(nil)
            }
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
        case .githubAvatar(let owner, let fallbackLabel):
            if let image = cachedGitHubImage(owner: owner) {
                imageCache[source] = image
                completion(image)
                return
            }

            // Network state never delays or destabilizes the outline. The
            // deterministic local identity is replaced only after a verified
            // GitHub image arrives.
            completion(Self.generatedImage(label: fallbackLabel))
            let ownerKey = owner.lowercased()
            remoteCompletions[ownerKey, default: []].append(
                PendingRemoteCompletion(source: source, completion: completion)
            )
            guard remoteTasks[ownerKey] == nil,
                  let url = Self.githubAvatarURL(owner: owner)
            else { return }
            let loader = remoteDataLoader
            remoteTasks[ownerKey] = Task { [weak self] in
                do {
                    let data = try await loader(url)
                    try Task.checkCancellation()
                    self?.finishRemoteLoad(data: data, owner: owner)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.finishRemoteLoad(data: nil, owner: owner)
                }
            }
        case .generated(let label):
            let image = Self.generatedImage(label: label)
            imageCache[source] = image
            completion(image)
        }
    }

    static func githubAvatarURL(owner: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(owner).png"
        components.queryItems = [URLQueryItem(name: "size", value: "64")]
        return components.url
    }

    private func finishRemoteLoad(
        data: Data?,
        owner: String
    ) {
        let ownerKey = owner.lowercased()
        remoteTasks[ownerKey] = nil
        let completions = remoteCompletions.removeValue(forKey: ownerKey) ?? []
        guard let data,
              data.count <= FileExplorerProjectIconResolver.maxRemoteImageBytes,
              FileExplorerProjectIconResolver.isSupportedRasterImage(data),
              let decoded = NSImage(data: data)
        else {
            failedSources.formUnion(completions.map(\.source))
            return
        }
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: cachedGitHubImageURL(owner: owner), options: .atomic)
        let image = Self.sidebarImage(decoded)
        completions.forEach {
            imageCache[$0.source] = image
            $0.completion(image)
        }
    }

    private func cachedGitHubImage(owner: String) -> NSImage? {
        let url = cachedGitHubImageURL(owner: owner)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modifiedAt) <= Self.remoteCacheLifetime,
              let data = try? Data(contentsOf: url),
              data.count <= FileExplorerProjectIconResolver.maxRemoteImageBytes,
              FileExplorerProjectIconResolver.isSupportedRasterImage(data),
              let image = NSImage(data: data)
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Self.sidebarImage(image)
    }

    private func cachedGitHubImageURL(owner: String) -> URL {
        cacheDirectory.appendingPathComponent("github-\(owner.lowercased()).png")
    }

    nonisolated private static func fetchRemoteImage(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
        request.setValue("image/png,image/jpeg,image/webp", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let finalHost = response.url?.host?.lowercased(),
              finalHost == "github.com" || finalHost.hasSuffix(".githubusercontent.com")
        else {
            throw URLError(.badServerResponse)
        }
        return data
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
