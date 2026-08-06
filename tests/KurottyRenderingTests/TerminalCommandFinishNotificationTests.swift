import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// Command-finish banners used to fire for every command that ended in an
/// unfocused pane, so alt-tabbing away and running `ls` raised one. The filter
/// has to live here rather than in Notification Center: a user who mutes the app
/// loses OSC 9/777/1337 along with it.
final class TerminalCommandFinishNotificationTests: XCTestCase {
    private let mode = TerminalCommandFinishNotificationMode.self
    private let policy = TerminalCommandFinishNotificationPolicy.self

    // MARK: - Policy decisions

    func testOffNeverNotifiesEvenForALongUnfocusedCommand() {
        XCTAssertFalse(policy.shouldNotify(
            mode: .off,
            minimumDuration: 10,
            actualDuration: 3_600,
            isFocused: false
        ))
    }

    func testUnfocusedNotifiesOnlyWhenTheUserIsLookingElsewhere() {
        XCTAssertTrue(policy.shouldNotify(
            mode: .unfocused,
            minimumDuration: 10,
            actualDuration: 30,
            isFocused: false
        ))
        XCTAssertFalse(policy.shouldNotify(
            mode: .unfocused,
            minimumDuration: 10,
            actualDuration: 30,
            isFocused: true
        ))
    }

    func testAlwaysNotifiesTheFocusedPaneToo() {
        XCTAssertTrue(policy.shouldNotify(
            mode: .always,
            minimumDuration: 10,
            actualDuration: 30,
            isFocused: true
        ))
    }

    func testACommandShorterThanTheThresholdStaysSilentInEveryMode() {
        // The background `ls` that made people mute the app.
        XCTAssertFalse(policy.shouldNotify(
            mode: .unfocused,
            minimumDuration: 10,
            actualDuration: 0.2,
            isFocused: false
        ))
        XCTAssertFalse(policy.shouldNotify(
            mode: .always,
            minimumDuration: 10,
            actualDuration: 0.2,
            isFocused: false
        ))
    }

    func testACommandExactlyAtTheThresholdNotifies() {
        XCTAssertTrue(policy.shouldNotify(
            mode: .unfocused,
            minimumDuration: 10,
            actualDuration: 10,
            isFocused: false
        ))
    }

    func testAnUnknownDurationCountsAsTooShort() {
        // OSC 133;D carries no duration when the shell integration never timed
        // the command. Without evidence the user walked away, a false banner
        // costs more than a missed one.
        XCTAssertFalse(policy.shouldNotify(
            mode: .unfocused,
            minimumDuration: 10,
            actualDuration: nil,
            isFocused: false
        ))
        XCTAssertFalse(policy.shouldNotify(
            mode: .always,
            minimumDuration: 0.5,
            actualDuration: nil,
            isFocused: false
        ))
    }

    func testAZeroThresholdNotifiesEvenWithoutADuration() {
        // Zero means "every command", which an untimed completion must not veto.
        XCTAssertTrue(policy.shouldNotify(
            mode: .unfocused,
            minimumDuration: 0,
            actualDuration: nil,
            isFocused: false
        ))
        XCTAssertTrue(policy.shouldNotify(
            mode: .unfocused,
            minimumDuration: 0,
            actualDuration: 0,
            isFocused: false
        ))
    }

    // MARK: - Mode parsing

    func testTheDefaultModeIsUnfocused() {
        XCTAssertEqual(mode.default, .unfocused)
        XCTAssertEqual(
            mode.parse(SettingsDefaults.notifyOnCommandFinish),
            .unfocused,
            "the Core-side raw default must name a mode the app understands"
        )
        XCTAssertEqual(SettingsDefaults.minimumCommandDurationSeconds, 10)
    }

    func testAHandEditedModeStillParses() {
        XCTAssertEqual(mode.parse(" Always "), .always)
        XCTAssertEqual(mode.parse("OFF"), .off)
        XCTAssertNil(mode.parse("sometimes"))
    }

    // MARK: - Settings round-trip

    func testTheDefaultsCarryTheDocumentedNotificationValues() {
        XCTAssertEqual(AppSettings.default.terminal.notifyOnCommandFinish, "unfocused")
        XCTAssertEqual(AppSettings.default.terminal.commandFinishNotificationMode, .unfocused)
        XCTAssertEqual(AppSettings.default.terminal.minimumCommandDurationSeconds, 10)
    }

    func testSettingsWithoutTheNotificationKeysStillDecode() throws {
        // Files written by schema 17 and earlier simply lack the keys; they must
        // take the defaults rather than failing the whole document.
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var terminal = try XCTUnwrap(object["terminal"] as? [String: Any])
        terminal.removeValue(forKey: "notifyOnCommandFinish")
        terminal.removeValue(forKey: "minimumCommandDurationSeconds")
        object["terminal"] = terminal
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)

        XCTAssertEqual(decoded.terminal.notifyOnCommandFinish, SettingsDefaults.notifyOnCommandFinish)
        XCTAssertEqual(
            decoded.terminal.minimumCommandDurationSeconds,
            SettingsDefaults.minimumCommandDurationSeconds
        )
    }

    func testAnExplicitChoiceSurvivesAnEncodeDecodeRoundTrip() throws {
        var settings = AppSettings.default
        settings.terminal.notifyOnCommandFinish = "always"
        settings.terminal.minimumCommandDurationSeconds = 45

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.terminal.commandFinishNotificationMode, .always)
        XCTAssertEqual(decoded.terminal.minimumCommandDurationSeconds, 45)
        XCTAssertEqual(
            AppSettingsNormalizer.normalized(decoded).terminal.commandFinishNotificationMode,
            .always
        )
    }

    func testNormalizationRewritesAnUnknownModeAndClampsTheThreshold() {
        var settings = AppSettings.default
        settings.terminal.notifyOnCommandFinish = "whenever"
        settings.terminal.minimumCommandDurationSeconds = -5

        let normalized = AppSettingsNormalizer.normalized(settings)

        // The saved file has to say what the app will actually do.
        XCTAssertEqual(normalized.terminal.notifyOnCommandFinish, "unfocused")
        XCTAssertEqual(
            normalized.terminal.minimumCommandDurationSeconds,
            SettingsDefaults.minimumAllowedCommandDurationSeconds
        )

        var tooLong = AppSettings.default
        tooLong.terminal.minimumCommandDurationSeconds =
            SettingsDefaults.maximumAllowedCommandDurationSeconds + 1
        XCTAssertEqual(
            AppSettingsNormalizer.normalized(tooLong).terminal.minimumCommandDurationSeconds,
            SettingsDefaults.maximumAllowedCommandDurationSeconds
        )
    }

    func testACaseVariantModeNormalizesToItsCanonicalSpelling() {
        var settings = AppSettings.default
        settings.terminal.notifyOnCommandFinish = "  ALWAYS "

        XCTAssertEqual(AppSettingsNormalizer.normalized(settings).terminal.notifyOnCommandFinish, "always")
    }

    func testSettingsWrittenBeforeSchemaEighteenLandOnTheDefaults() {
        // Those files predate the filter, so whatever they hold for these keys
        // carries no user intent.
        var settings = AppSettings.default
        settings.schemaVersion = 17
        settings.terminal.notifyOnCommandFinish = "always"
        settings.terminal.minimumCommandDurationSeconds = 120

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertEqual(normalized.terminal.notifyOnCommandFinish, SettingsDefaults.notifyOnCommandFinish)
        XCTAssertEqual(
            normalized.terminal.minimumCommandDurationSeconds,
            SettingsDefaults.minimumCommandDurationSeconds
        )
    }

    // MARK: - Validation

    func testAnUnsupportedModeAndAnOutOfRangeThresholdAreReported() {
        var settings = AppSettings.default
        settings.terminal.notifyOnCommandFinish = "loud"
        settings.terminal.minimumCommandDurationSeconds =
            SettingsDefaults.maximumAllowedCommandDurationSeconds + 1

        let report = AppSettingsValidation.report(for: settings) { _ in true }

        XCTAssertTrue(report.issues.contains {
            $0.key == .terminalNotifyOnCommandFinish
                && $0.code == .unsupportedValue
                && $0.severity == .error
                && $0.lifecycle == .liveApplied
                && $0.message.contains("unfocused")
        })
        XCTAssertTrue(report.issues.contains {
            $0.key == .terminalMinimumCommandDurationSeconds
                && $0.code == .valueOutOfRange
                && $0.lifecycle == .liveApplied
        })
    }

    func testTheDefaultNotificationSettingsValidateCleanly() {
        let report = AppSettingsValidation.report(for: .default) { _ in true }

        XCTAssertFalse(report.issues.contains {
            $0.key == .terminalNotifyOnCommandFinish || $0.key == .terminalMinimumCommandDurationSeconds
        })
    }
}
