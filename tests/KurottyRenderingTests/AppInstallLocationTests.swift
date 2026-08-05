import AppKit
import XCTest
@testable import KurottyApp

/// The app refuses to update itself from a read-only or temporary location.
/// These cover the decision that drives the move offer: it must fire for the
/// DMG case, stay silent for a normal install, and never offer to copy a
/// translocated bundle, because that copy is not the app the user downloaded.
final class AppInstallLocationTests: XCTestCase {
    private let home = "/Users/tester"

    private func verdict(
        _ path: String,
        readOnly: Bool = false
    ) -> AppInstallLocation.Verdict {
        AppInstallLocation.verdict(
            bundlePath: path,
            homeDirectoryPath: home,
            isVolumeReadOnly: readOnly
        )
    }

    func testAnInstalledAppIsLeftAlone() {
        XCTAssertEqual(verdict("/Applications/kurotty.app"), .installed)
        XCTAssertEqual(verdict("/Applications/Utilities/kurotty.app"), .installed)
        XCTAssertEqual(verdict("/System/Applications/kurotty.app"), .installed)
        XCTAssertEqual(verdict("\(home)/Applications/kurotty.app"), .installed)
    }

    func testAReadOnlyVolumeIsOfferedAMove() {
        let verdict = verdict("/Volumes/Kurotty 1/kurotty.app", readOnly: true)
        XCTAssertEqual(verdict, .readOnlyVolume)
        XCTAssertTrue(verdict.isSelfCorrectable)
    }

    func testTemporaryDirectoriesAreOfferedAMove() {
        XCTAssertEqual(verdict("/private/var/folders/ab/xyz/T/kurotty.app"), .temporary)
        XCTAssertEqual(verdict("/private/tmp/kurotty.app"), .temporary)
        XCTAssertEqual(verdict("/tmp/kurotty.app"), .temporary)
    }

    func testATranslocatedBundleIsReportedButNeverCopied() {
        let path = "/private/var/folders/ab/xyz/T/AppTranslocation/9F3C/d/kurotty.app"
        let verdict = verdict(path, readOnly: true)
        XCTAssertEqual(verdict, .translocated)
        // Copying this path would install the randomized copy instead of the
        // bundle sitting in the user's Downloads folder.
        XCTAssertFalse(verdict.isSelfCorrectable)
    }

    func testTranslocationWinsOverTheTemporaryAndReadOnlyChecks() {
        // A translocated bundle is both read-only and under a temporary path,
        // so ordering is what keeps it out of the self-correctable branch.
        let path = "/private/var/folders/ab/xyz/T/AppTranslocation/9F3C/d/kurotty.app"
        XCTAssertEqual(verdict(path, readOnly: false), .translocated)
    }

    func testAWritableLocationOutsideApplicationsIsLeftAlone() {
        // Sparkle can update in place from a writable folder, so there is no
        // reason to interrupt the launch with a move offer.
        XCTAssertEqual(verdict("\(home)/Downloads/kurotty.app"), .installed)
        XCTAssertEqual(verdict("\(home)/dev/kurotty/.build/kurotty.app"), .installed)
    }

    func testAPathThatMerelyStartsWithAnInstalledPrefixIsNotTreatedAsInstalled() {
        XCTAssertEqual(
            verdict("/Applications Backup/kurotty.app", readOnly: true),
            .readOnlyVolume
        )
    }

    func testEveryPromptStringResolvesInEveryLanguage() {
        let keys: [L10nKey] = [
            .moveToApplicationsTitle, .moveToApplicationsMessage,
            .moveToApplications, .moveToApplicationsLater,
            .moveToApplicationsFailedTitle, .moveToApplicationsFailedMessage,
            .translocatedMessage,
        ]
        for language in AppLanguage.allCases {
            for key in keys {
                let value = AppLocalization.string(key, language: language)
                XCTAssertFalse(
                    value.isEmpty,
                    "\(key) is missing for \(language.rawValue)"
                )
                XCTAssertNotEqual(
                    value, key.rawValue,
                    "\(key) fell back to its key for \(language.rawValue)"
                )
            }
        }
    }
}

/// macOS resolves an embedded framework's localization against the host
/// bundle's declared languages, so Sparkle's dialogs stay English unless the
/// app declares the languages it supports.
final class BundleLocalizationDeclarationTests: XCTestCase {
    private func packagingScript(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return try String(
            contentsOf: url.appendingPathComponent("scripts/\(name)"),
            encoding: .utf8
        )
    }

    func testBothPackagingScriptsDeclareEveryAppLanguage() throws {
        for script in ["install-app.sh", "package-release.sh"] {
            let source = try packagingScript(script)
            XCTAssertTrue(
                source.contains("<key>CFBundleLocalizations</key>"),
                "\(script) does not declare CFBundleLocalizations"
            )
            for language in AppLanguage.allCases {
                XCTAssertTrue(
                    source.contains("<string>\(language.rawValue)</string>"),
                    "\(script) does not declare \(language.rawValue)"
                )
            }
        }
    }
}
