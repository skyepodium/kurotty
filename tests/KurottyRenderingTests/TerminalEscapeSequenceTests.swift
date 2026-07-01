import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class TerminalEscapeSequenceTests: XCTestCase {
    func testTwoByteEscapeDesignatorIntroducersIncludeTmuxCharsetSequences() {
        for scalar in ["(", ")", "*", "+", "-", ".", "/", "%"].compactMap(\.unicodeScalars.first) {
            XCTAssertTrue(TerminalEscapeSequence.beginsTwoByteDesignator(scalar), "\(scalar)")
        }
    }

    func testTwoByteEscapeDesignatorIntroducersExcludeCsiAndOscIntroducers() throws {
        for scalar in ["[", "]", "#", "7", "8", "D", "E", "M", "c"].compactMap(\.unicodeScalars.first) {
            XCTAssertFalse(TerminalEscapeSequence.beginsTwoByteDesignator(scalar), "\(scalar)")
        }
    }

    func testTwoByteDecPrivateIntroducerIsSeparateFromCharsetDesignators() throws {
        let decPrivate = try XCTUnwrap("#".unicodeScalars.first)
        let charset = try XCTUnwrap("(".unicodeScalars.first)

        XCTAssertTrue(TerminalEscapeSequence.beginsTwoByteDecPrivate(decPrivate))
        XCTAssertFalse(TerminalEscapeSequence.beginsTwoByteDecPrivate(charset))
    }

    func testDeviceAttributesResponsesMatchRequestedQueryType() {
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters("")), "\u{1b}[?1;2c")
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters("0")), "\u{1b}[?1;2c")
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters(">")), "\u{1b}[>0;0;0c")
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters(">0")), "\u{1b}[>0;0;0c")
        XCTAssertNil(TerminalDeviceAttributes.response(for: CsiParameters("?1;2")))
        XCTAssertNil(TerminalDeviceAttributes.response(for: CsiParameters("=1")))
    }

    func testCsiParametersPreserveSgrColonSubparameters() {
        let underlineOff = CsiParameters("4:0")
        XCTAssertEqual(underlineOff.elements.map(\.values), [[4, 0]])

        let trueColor = CsiParameters("38:2::1:2:3;4:3")
        XCTAssertEqual(trueColor.elements.map(\.values), [[38, 2, 0, 1, 2, 3], [4, 3]])
        XCTAssertEqual(trueColor.values, [38, 2, 0, 1, 2, 3, 4, 3])
    }

    func testPrivateCsiMIsKeyboardProtocolNotSgr() {
        let keyboardProtocolMode = CsiParameters(">4;2")

        XCTAssertTrue(keyboardProtocolMode.isPrivate)
        XCTAssertEqual(keyboardProtocolMode.prefix, ">")
        XCTAssertFalse(TerminalSgrPolicy.shouldApplySgr(for: keyboardProtocolMode))
        XCTAssertTrue(TerminalSgrPolicy.shouldApplySgr(for: CsiParameters("4;2")))
    }

    func testTerminalResponsesAreSuppressedWhenPtyWouldEchoThem() {
        XCTAssertFalse(TerminalLineDiscipline.canReceiveTerminalResponseWithoutEcho(localFlags: tcflag_t(ECHO)))
        XCTAssertTrue(TerminalLineDiscipline.canReceiveTerminalResponseWithoutEcho(localFlags: 0))
    }
}
