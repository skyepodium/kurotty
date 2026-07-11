import Darwin
import Foundation

enum ReleaseArtifactSmokeTest {
    private static let argument = "--release-artifact-smoke-test"

    static func handleIfNeeded(arguments: [String]) -> Bool {
        guard arguments.contains(argument) else { return false }

        do {
            try verifyInstalledLayout()
            print("release artifact smoke test passed: \(Bundle.main.bundleURL.path)")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("release artifact smoke test failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func verifyInstalledLayout() throws {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            throw Failure("executable is not running from an app bundle")
        }

        let resourcesURL = try requiredDirectory(Bundle.main.resourceURL, named: "Contents/Resources")
        let resourceBundleURL = resourcesURL.appendingPathComponent("Kurotty_KurottyApp.bundle", isDirectory: true)
        guard let resourceBundle = Bundle(url: resourceBundleURL) else {
            throw Failure("cannot open packaged SwiftPM resource bundle at \(resourceBundleURL.path)")
        }

        try requireResource("kurotty", extension: "png", in: resourceBundle)
        try requireResource("ShellIntegration", extension: nil, in: resourceBundle)
        try requireFile(resourceBundleURL.appendingPathComponent("ShellIntegration/zsh/.zshenv"))
        try requireFile(resourceBundleURL.appendingPathComponent("ShellIntegration/bash/kurotty.bash"))
        try requireFile(resourceBundleURL.appendingPathComponent("ShellIntegration/fish/share/fish/vendor_conf.d/kurotty-shell-integration.fish"))
        try requireFile(resourcesURL.appendingPathComponent("kurotty.icns"))

        let coreLibraryURL = resourcesURL.appendingPathComponent("libkurotty_core.dylib")
        try requireFile(coreLibraryURL)
        guard let handle = dlopen(coreLibraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw Failure("cannot load packaged core library: \(String(cString: dlerror()))")
        }
        dlclose(handle)

        let sparkleExecutable = appURL.appendingPathComponent(
            "Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle"
        )
        try requireFile(sparkleExecutable)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let version, !version.isEmpty else {
            throw Failure("CFBundleShortVersionString is missing")
        }
    }

    private static func requiredDirectory(_ url: URL?, named name: String) throws -> URL {
        guard let url else { throw Failure("missing directory: \(name)") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure("missing directory: \(url.path)")
        }
        return url
    }

    private static func requireResource(_ name: String, extension fileExtension: String?, in bundle: Bundle) throws {
        guard bundle.url(forResource: name, withExtension: fileExtension) != nil else {
            throw Failure("missing resource: \(name)\(fileExtension.map { ".\($0)" } ?? "")")
        }
    }

    private static func requireFile(_ url: URL) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw Failure("missing or unreadable file: \(url.path)")
        }
    }

    private struct Failure: LocalizedError, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }

        var errorDescription: String? { description }
    }
}
