import Foundation
import XCTest
@testable import KurottyApp
@testable import KurottyCore

final class TerminalLinkTrustTests: XCTestCase {
    private let policy = TerminalSecurityPolicy.default

    // MARK: - Trust tiers

    func testOSC8LinkWhoseVisibleTextIsNotItsTargetIsUntrusted() {
        XCTAssertEqual(
            TerminalLinkTrust.tier(
                urlString: "https://evil.example/steal",
                displayText: "https://x.ai/grok",
                provenance: .oscHyperlink
            ),
            .untrusted(.displayTextMismatch)
        )
    }

    func testOSC8LinkWhoseVisibleTextIsItsTargetIsTrusted() {
        XCTAssertEqual(
            TerminalLinkTrust.tier(
                urlString: "https://x.ai/grok",
                displayText: "https://x.ai/grok",
                provenance: .oscHyperlink
            ),
            .trusted
        )
    }

    func testSurroundingWhitespaceDoesNotMakeAMatchingLabelMismatch() {
        XCTAssertEqual(
            TerminalLinkTrust.tier(
                urlString: "https://x.ai/grok",
                displayText: "  https://x.ai/grok ",
                provenance: .oscHyperlink
            ),
            .trusted
        )
    }

    func testSchemeOutsideTheReadableSetIsUntrustedEvenWhenTextMatches() {
        for urlString in ["ssh://example.com/repo", "javascript:alert(1)", "data:text/html,x"] {
            XCTAssertEqual(
                TerminalLinkTrust.tier(
                    urlString: urlString,
                    displayText: urlString,
                    provenance: .oscHyperlink
                ),
                .untrusted(.untrustedScheme),
                urlString
            )
        }
    }

    func testReadableSchemesStayTrustedWhenTheTextIsTheTarget() {
        for urlString in [
            "http://example.com/a",
            "https://example.com/a",
            "file:///tmp/report.txt",
            "mailto:someone@example.com",
        ] {
            XCTAssertEqual(
                TerminalLinkTrust.tier(
                    urlString: urlString,
                    displayText: urlString,
                    provenance: .oscHyperlink
                ),
                .trusted,
                urlString
            )
        }
    }

    func testControlCharactersAndNewlinesMakeATargetUntrusted() {
        for urlString in [
            "https://example.com/\u{0007}evil",
            "https://example.com/a\nb",
            "https://example.com/\u{202E}gpj.exe",
        ] {
            XCTAssertEqual(
                TerminalLinkTrust.tier(
                    urlString: urlString,
                    displayText: urlString,
                    provenance: .textScan
                ),
                .untrusted(.unsafeCharacters),
                urlString
            )
        }
    }

    func testUserinfoMakesATargetUntrustedEvenForAScannedURL() {
        XCTAssertEqual(
            TerminalLinkTrust.tier(
                urlString: "https://apple.com:secret@evil.example/reset",
                displayText: "https://apple.com:secret@evil.example/reset",
                provenance: .textScan
            ),
            .untrusted(.embeddedUserinfo)
        )
    }

    func testScannedURLThatIsItsOwnTextStaysTrusted() {
        XCTAssertEqual(
            TerminalLinkTrust.tier(
                urlString: "https://x.ai/grok",
                displayText: "https://x.ai/grok",
                provenance: .textScan
            ),
            .trusted
        )
    }

    /// A `path:line:col` link is scanned from text whose form is not the
    /// `file://` URL it resolves to. That difference is the scanner's own work,
    /// not a program's claim, so it must not raise a prompt.
    func testScannedFileLinkStaysTrustedThoughItsTargetIsNotItsText() {
        XCTAssertEqual(
            TerminalLinkTrust.tier(
                urlString: "file:///Users/skye/project/main.swift",
                displayText: "main.swift:42",
                provenance: .textScan
            ),
            .trusted
        )
    }

    func testUnparsableTargetIsUntrusted() {
        XCTAssertEqual(
            TerminalLinkTrust.tier(urlString: "not a url", displayText: "not a url", provenance: .textScan),
            .untrusted(.unparsableTarget)
        )
    }

    // MARK: - Safe target rendering

    func testUserinfoIsNeverRenderedAsIfItWereTheHost() {
        let target = TerminalLinkTrust.safeTarget(forURLString: "https://apple.com:secret@evil.example/reset?a=1")

        XCTAssertEqual(target.host, "evil.example")
        XCTAssertFalse(target.displayURLString.contains("apple.com"))
        XCTAssertFalse(target.displayURLString.contains("secret"))
        XCTAssertTrue(target.displayURLString.contains("evil.example/reset?a=1"))
        // What actually opens keeps the userinfo: dropping it would open a
        // different address than the one the user was shown and agreed to.
        XCTAssertEqual(target.resolvedURLString, "https://apple.com:secret@evil.example/reset?a=1")
    }

    func testControlCharactersAreStrippedFromWhatIsShownAndOpened() {
        let target = TerminalLinkTrust.safeTarget(forURLString: "https://example.com/a\u{0007}b\nc")

        XCTAssertEqual(target.displayURLString, "https://example.com/abc")
        XCTAssertEqual(target.resolvedURLString, "https://example.com/abc")
        XCTAssertEqual(target.host, "example.com")
    }

    func testTargetWithoutUserinfoIsShownUnchanged() {
        let target = TerminalLinkTrust.safeTarget(forURLString: "https://x.ai/grok?q=a@b")

        XCTAssertEqual(target.displayURLString, "https://x.ai/grok?q=a@b")
        XCTAssertEqual(target.host, "x.ai")
    }

    // MARK: - Activation decisions

    func testMismatchedOSC8LinkRequiresConfirmationShowingTheRealTarget() {
        let decision = TerminalLinkActivation.decision(
            urlString: "https://evil.example/steal",
            displayText: "https://x.ai/grok",
            provenance: .oscHyperlink,
            policy: policy
        )

        XCTAssertEqual(decision.outcome, .ask)
        XCTAssertTrue(decision.requiresConfirmation)
        XCTAssertEqual(decision.safeTarget.host, "evil.example")
        XCTAssertEqual(decision.openURL, URL(string: "https://evil.example/steal"))
    }

    func testMatchingOSC8LinkOpensWithoutAnExtraPrompt() {
        let decision = TerminalLinkActivation.decision(
            urlString: "https://x.ai/grok",
            displayText: "https://x.ai/grok",
            provenance: .oscHyperlink,
            policy: policy
        )

        XCTAssertEqual(decision.outcome, .allow)
        XCTAssertFalse(decision.requiresConfirmation)
    }

    func testPlainScannedURLKeepsOpeningWithoutAPrompt() {
        let decision = TerminalLinkActivation.decision(
            urlString: "https://x.ai/grok",
            displayText: "https://x.ai/grok",
            provenance: .textScan,
            policy: policy
        )

        XCTAssertEqual(decision.outcome, .allow)
    }

    /// The tier narrows and never widens: a scheme the security policy refuses
    /// is not promoted into a question just because the label matched.
    func testRefusedSchemeStaysRefusedRatherThanBecomingAQuestion() {
        let decision = TerminalLinkActivation.decision(
            urlString: "javascript:alert(1)",
            displayText: "javascript:alert(1)",
            provenance: .oscHyperlink,
            policy: policy
        )

        XCTAssertEqual(decision.outcome, .deny)
    }

    func testUserinfoTargetLosesTheSilentOpenItsSchemeWouldHaveEarned() throws {
        let urlString = "https://apple.com@evil.example/reset"
        let policyAlone = policy.userActivatedLinkDecision(for: try XCTUnwrap(URL(string: urlString)))

        let decision = TerminalLinkActivation.decision(
            urlString: urlString,
            displayText: urlString,
            provenance: .textScan,
            policy: policy
        )

        XCTAssertEqual(policyAlone, .allow)
        XCTAssertEqual(decision.outcome, .ask)
        XCTAssertEqual(decision.tier, .untrusted(.embeddedUserinfo))
    }

    // MARK: - Provenance tagging on detected links

    func testOSC8CellsProduceHyperlinkProvenanceCarryingTheVisibleLabel() throws {
        let row = cells("Ask Grok", linkURL: "https://evil.example/steal")

        let ranges = TerminalLinkRange.findAll(in: row, row: 0)

        XCTAssertEqual(ranges.map(\.provenance), [.oscHyperlink])
        XCTAssertEqual(ranges.map(\.displayText), ["Ask Grok"])
        XCTAssertEqual(
            TerminalLinkActivation.decision(for: try XCTUnwrap(ranges.first), policy: policy).outcome,
            .ask
        )
    }

    func testScannedURLProducesTextScanProvenanceAndOpensDirectly() throws {
        let row = cells("Open https://x.ai/grok now")

        let ranges = TerminalLinkRange.findAll(in: row, row: 0)

        XCTAssertEqual(ranges.map(\.provenance), [.textScan])
        XCTAssertEqual(ranges.map(\.displayText), ["https://x.ai/grok"])
        XCTAssertEqual(
            TerminalLinkActivation.decision(for: try XCTUnwrap(ranges.first), policy: policy).outcome,
            .allow
        )
    }

    func testWrappedOSC8LinkCarriesTheWholeLabelOnEveryPhysicalRow() {
        var firstRow = cells("Read the ", linkURL: "https://evil.example/steal")
        firstRow[firstRow.count - 1].wrapsToNextRow = true
        let rows = [firstRow, cells("release notes", linkURL: "https://evil.example/steal")]

        let ranges = TerminalLinkRange.findAll(in: rows, startingRow: 0)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(Set(ranges.map(\.displayText)), ["Read the release notes"])
        XCTAssertEqual(Set(ranges.map(\.provenance)), [.oscHyperlink])
    }

    private func cells(_ text: String, linkURL: String? = nil) -> [TerminalScreenCell] {
        text.map { character in
            TerminalScreenCell(character: character, linkURL: linkURL)
        }
    }
}
