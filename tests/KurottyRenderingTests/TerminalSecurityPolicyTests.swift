import Foundation
import XCTest
@testable import KurottyApp

final class TerminalSecurityPolicyTests: XCTestCase {
    func testOSC52LocalWriteAllowedButRemoteWriteAsksAndRemoteReadDeniedByDefault() {
        let policy = TerminalSecurityPolicy.default

        XCTAssertEqual(policy.decision(for: .osc52Write, origin: .local), .allow)
        XCTAssertEqual(policy.decision(for: .osc52Write, origin: .remote), .ask)
        XCTAssertEqual(policy.decision(for: .osc52Read, origin: .local), .ask)
        XCTAssertEqual(policy.decision(for: .osc52Read, origin: .remote), .deny)
    }

    func testClipboardRemoteOperationsAreConservativeByDefault() {
        let policy = TerminalSecurityPolicy.default

        XCTAssertEqual(policy.decision(for: .clipboardWrite, origin: .local), .allow)
        XCTAssertEqual(policy.decision(for: .clipboardWrite, origin: .remote), .ask)
        XCTAssertEqual(policy.decision(for: .clipboardRead, origin: .local), .ask)
        XCTAssertEqual(policy.decision(for: .clipboardRead, origin: .remote), .deny)
        XCTAssertEqual(policy.decision(for: .clipboardWrite, origin: .unknown), .ask)
    }

    func testURLSchemesAreAllowlisted() throws {
        let policy = TerminalSecurityPolicy.default

        XCTAssertEqual(policy.linkOpenDecision(for: try XCTUnwrap(URL(string: "https://example.com"))), .ask)
        XCTAssertEqual(policy.linkOpenDecision(for: try XCTUnwrap(URL(string: "http://example.com"))), .ask)
        XCTAssertEqual(policy.linkOpenDecision(for: try XCTUnwrap(URL(string: "ssh://example.com"))), .deny)
        XCTAssertEqual(policy.linkOpenDecision(for: try XCTUnwrap(URL(string: "javascript:alert(1)"))), .deny)
    }

    func testFileURLHandlingRequiresConfirmationOrBlocksNonLocalHosts() throws {
        let policy = TerminalSecurityPolicy.default

        XCTAssertEqual(policy.linkOpenDecision(for: URL(fileURLWithPath: "/tmp/report.txt")), .ask)
        XCTAssertEqual(policy.linkOpenDecision(for: try XCTUnwrap(URL(string: "file://localhost/tmp/report.txt"))), .ask)
        XCTAssertEqual(policy.linkOpenDecision(for: try XCTUnwrap(URL(string: "file://server/share/report.txt"))), .deny)
    }

    func testAIContextExportKeepsSecretRedactionMetadataExplicit() {
        let policy = TerminalSecurityPolicy.default

        XCTAssertEqual(
            policy.aiContextExportDecision(.init(rawOutputRequested: false, secretRedactionEnabled: true)),
            .allow
        )
        XCTAssertEqual(
            policy.aiContextExportDecision(.init(rawOutputRequested: true, secretRedactionEnabled: true)),
            .ask
        )
        XCTAssertEqual(
            policy.aiContextExportDecision(.init(rawOutputRequested: false, secretRedactionEnabled: false)),
            .deny
        )
        XCTAssertEqual(policy.aiContextMetadata.secretExposure, .redacted)
        XCTAssertFalse(policy.aiContextMetadata.rawOutputIncludedByDefault)
    }
}
