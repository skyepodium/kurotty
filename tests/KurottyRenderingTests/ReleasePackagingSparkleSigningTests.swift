import Foundation
import XCTest

final class ReleasePackagingSparkleSigningTests: XCTestCase {
    func testUpdateContractLinterPassesTheRepository() throws {
        let result = try runUpdateContractLinter(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("update contract: invariants hold"))
    }

    func testUpdateContractLinterRejectsSignatureCreationWithDeep() throws {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-update-contract-\(UUID().uuidString)")
        let fixtureScripts = fixtureRoot.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: fixtureScripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        for name in ["check-update-contract", "install-app", "package-release", "sign-app-bundle", "verify-release-artifact"] {
            let source = repositoryRoot.appendingPathComponent("scripts/\(name).sh")
            let destination = fixtureScripts.appendingPathComponent("\(name).sh")
            try FileManager.default.copyItem(at: source, to: destination)
        }

        let packageURL = fixtureScripts.appendingPathComponent("package-release.sh")
        var packageSource = try String(contentsOf: packageURL, encoding: .utf8)
        packageSource = packageSource.replacingOccurrences(
            of: "sign_kurotty_app_bundle \"$APP_BUNDLE\" \"$SIGN_IDENTITY\"",
            with: "codesign --force --deep --sign - \"$APP_BUNDLE\""
        )
        try packageSource.write(to: packageURL, atomically: true, encoding: .utf8)

        let result = try runUpdateContractLinter(root: fixtureRoot)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("must never create or replace a signature"), result.output)
    }

    func testRepositoryRulesTreatAutomaticUpdateAsHistoricalCompatibility() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let agentRules = try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        let testingGuide = try String(contentsOf: root.appendingPathComponent("docs/testing.md"), encoding: .utf8)
        let normalizedTestingGuide = testingGuide.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let ciWorkflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        let releaseWorkflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)

        XCTAssertTrue(agentRules.contains("Automatic update is an existing compatibility contract"))
        XCTAssertTrue(agentRules.contains("Never use `codesign --deep` to create or replace a signature"))
        XCTAssertTrue(agentRules.contains("immediately previous published DMG to the candidate release"))
        XCTAssertTrue(testingGuide.contains("## Automatic Update Regression Gate"))
        XCTAssertTrue(normalizedTestingGuide.contains("the old process exits"))
        XCTAssertTrue(normalizedTestingGuide.contains("the installed bundle version advances"))
        XCTAssertTrue(normalizedTestingGuide.contains("the candidate app relaunches"))
        XCTAssertTrue(ciWorkflow.contains("./scripts/check-update-contract.sh"))
        XCTAssertTrue(releaseWorkflow.contains("./scripts/check-update-contract.sh"))
    }

    func testPackageReleaseSignsSparkleHelpersBeforeFrameworkAndApp() throws {
        let source = try scriptSource(named: "package-release")
        let signingSource = try scriptSource(named: "sign-app-bundle")

        let sourceHelper = try XCTUnwrap(source.range(of: "source \"$ROOT_DIR/scripts/sign-app-bundle.sh\""))
        let signCall = try XCTUnwrap(source.range(of: "sign_kurotty_app_bundle \"$APP_BUNDLE\" \"$SIGN_IDENTITY\""))
        let verification = try XCTUnwrap(source.range(of: "scripts/verify-release-artifact.sh\" \"$DMG_PATH\" \"$VERSION\""))
        let downloader = try XCTUnwrap(signingSource.range(of: "sign_sparkle_component \"$sparkle_framework/Versions/Current/XPCServices/Downloader.xpc\""))
        let framework = try XCTUnwrap(signingSource.range(of: "sign_sparkle_component \"$sparkle_framework\""))
        let app = try XCTUnwrap(signingSource.range(of: "sign_code \"$app_bundle\""))

        XCTAssertLessThan(sourceHelper.lowerBound, signCall.lowerBound)
        XCTAssertLessThan(signCall.lowerBound, verification.lowerBound)
        XCTAssertLessThan(downloader.lowerBound, framework.lowerBound)
        XCTAssertLessThan(framework.lowerBound, app.lowerBound)
    }

    func testPackagingScriptsDoNotDeepSignSparkleOrTheAppBundle() throws {
        for script in ["install-app", "package-release"] {
            let source = try scriptSource(named: script)

            XCTAssertFalse(
                source.contains("codesign --force --deep"),
                "\(script).sh must sign nested Sparkle helpers explicitly instead of relying on --deep"
            )
        }
    }

    func testReleaseArtifactVerifierChecksSparkleInstallerComponents() throws {
        let source = try scriptSource(named: "verify-release-artifact")

        XCTAssertTrue(source.contains("verify_sparkle_signing \"$COPIED_APP\""))
        XCTAssertTrue(source.contains("Sparkle.framework/Versions/Current/XPCServices/Installer.xpc"))
        XCTAssertTrue(source.contains("Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc"))
        XCTAssertTrue(source.contains("Sparkle.framework/Versions/Current/Autoupdate"))
        XCTAssertTrue(source.contains("Sparkle.framework/Versions/Current/Updater.app"))
        XCTAssertTrue(source.contains("signature_team_identifier"))
        XCTAssertTrue(source.contains("Sparkle signing identity mismatch"))
        XCTAssertTrue(source.contains("codesign --verify --strict --verbose=2 \"$target\""))
    }

    private func scriptSource(named name: String) throws -> String {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/\(name).sh")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func runUpdateContractLinter(root: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/check-update-contract.sh").path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "KUROTTY_UPDATE_CONTRACT_ROOT": root.path
        ]) { _, fixture in fixture }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
