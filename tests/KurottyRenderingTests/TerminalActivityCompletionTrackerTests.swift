import XCTest
@testable import KurottyApp

final class TerminalActivityCompletionTrackerTests: XCTestCase {
    func testCompletesArbitraryInteractiveActivityAfterOutputQuiesces() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(submittedText: "describe the current work")

        let firstGeneration = try XCTUnwrap(tracker.recordOutput(byteCount: 20))
        let latestGeneration = try XCTUnwrap(tracker.recordOutput(byteCount: 80))

        XCTAssertNil(tracker.completeIfCurrent(generation: firstGeneration - 1))
        XCTAssertEqual(
            tracker.completeIfCurrent(generation: latestGeneration),
            .init(generation: latestGeneration, submittedText: "describe the current work", resultText: nil)
        )
        XCTAssertNil(tracker.completeIfCurrent(generation: latestGeneration))
    }

    func testDoesNotNotifyForEchoOnlyOrWithoutSubmittedInput() {
        var tracker = TerminalActivityCompletionTracker()
        XCTAssertNil(tracker.recordOutput(byteCount: 100))

        tracker.begin(submittedText: "hi")
        let generation = tracker.recordOutput(byteCount: 2)

        XCTAssertEqual(generation, tracker.generation)
        XCTAssertNil(tracker.completeIfCurrent(generation: tracker.generation))
    }

    func testExplicitProtocolSuppressesFallbackForCurrentSubmission() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(submittedText: "run checks")
        let generation = try XCTUnwrap(tracker.recordOutput(byteCount: 100))

        tracker.suppressCurrent()

        XCTAssertNil(tracker.completeIfCurrent(generation: generation))
        XCTAssertNil(tracker.recordOutput(byteCount: 100))
    }

    func testNewSubmissionInvalidatesEarlierQuietTimer() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(submittedText: "first")
        let first = try XCTUnwrap(tracker.recordOutput(byteCount: 100))
        tracker.begin(submittedText: "second")
        let second = try XCTUnwrap(tracker.recordOutput(byteCount: 100))

        XCTAssertNil(tracker.completeIfCurrent(generation: first))
        XCTAssertEqual(
            tracker.completeIfCurrent(generation: second)?.submittedText,
            "second"
        )
    }

    func testNotificationContentUsesProgramDirectoryAndResult() {
        XCTAssertEqual(
            TerminalActivityCompletionNotificationContent.make(
                resultText: "Hi.",
                runtimeMetadata: .init(command: "example-runner", workingDirectory: "/Users/example/dev/terminal"),
                terminalTitle: "release - grok",
                currentDirectory: "/Users/example/dev/kurotty"
            ),
            .init(
                title: "Example-runner",
                subtitle: "terminal",
                body: "Hi."
            )
        )
    }

    func testNotificationContentFallsBackWithoutResultOrProgramMetadata() {
        XCTAssertEqual(
            TerminalActivityCompletionNotificationContent.make(
                resultText: nil,
                runtimeMetadata: nil,
                terminalTitle: "",
                currentDirectory: "/"
            ),
            .init(title: "Terminal", subtitle: "Session", body: "Task finished")
        )
    }

    func testProgramNameUsesLastProducerTitleComponentWithoutKnownApplicationNames() {
        XCTAssertEqual(TerminalNotificationContext.programName(runtimeCommand: nil, terminalTitle: "Waiting - task - example-runner", currentDirectory: "/tmp/dev"), "Example-runner")
        XCTAssertEqual(TerminalNotificationContext.programName(runtimeCommand: nil, terminalTitle: "standalone", currentDirectory: "/tmp/dev"), "Standalone")
        XCTAssertEqual(TerminalNotificationContext.programName(runtimeCommand: nil, terminalTitle: "arbitrary task title", currentDirectory: "/tmp/dev"), "Terminal")
        XCTAssertEqual(TerminalNotificationContext.programName(runtimeCommand: nil, terminalTitle: "dev", currentDirectory: "/tmp/dev"), "Terminal")
        XCTAssertEqual(TerminalNotificationContext.programName(runtimeCommand: "codex", terminalTitle: "dev", currentDirectory: "/tmp/dev"), "Codex")
    }

    func testRuntimeMetadataParsesGenericCommandAndDirectoryFields() {
        XCTAssertEqual(
            TerminalRuntimeNotificationMetadata.parse("codex\t/Users/example/dev/terminal\n"),
            .init(command: "codex", workingDirectory: "/Users/example/dev/terminal")
        )
        XCTAssertNil(TerminalRuntimeNotificationMetadata.parse("missing separator"))
    }

    func testProcessArgumentsUseInvokedCommandInsteadOfInternalExecutablePath() {
        var bytes = withUnsafeBytes(of: Int32(1)) { Array($0) }
        bytes.append(contentsOf: "/opt/tools/codex-aarch64-apple-darwin".utf8)
        bytes.append(0)
        bytes.append(0)
        bytes.append(contentsOf: "codex".utf8)
        bytes.append(0)

        XCTAssertEqual(TerminalProcessArguments.commandName(fromKernProcArgs2: bytes), "codex")
    }

    func testOutputSummarySelectsInformativeChangedResultWithoutToolSpecificRules() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(
            submittedText: "hello",
            baselineText: "~/dev\n› hello\nExisting status"
        )
        let generation = try XCTUnwrap(tracker.recordOutput(byteCount: 200))

        let candidate = tracker.completeIfCurrent(
            generation: generation,
            currentText: """
            ~/dev
            › hello
            Existing status
            Thought for 0.1s
            Hello. What can I help you with today?
            Completed in 1.2s
            """
        )

        XCTAssertEqual(candidate?.resultText, "Hello. What can I help you with today?")
    }

    func testOutputSummaryIgnoresUnchangedScreenAndSubmittedInput() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(submittedText: "hello", baselineText: "~/dev\nhello")
        let generation = try XCTUnwrap(tracker.recordOutput(byteCount: 100))

        XCTAssertNil(
            tracker.completeIfCurrent(
                generation: generation,
                currentText: "~/dev\nhello"
            )?.resultText
        )
    }

    func testOutputSummaryIgnoresShortcutDenseControlHints() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(submittedText: "hello", baselineText: "~/dev\nhello")
        let generation = try XCTUnwrap(tracker.recordOutput(byteCount: 200))

        let candidate = tracker.completeIfCurrent(
            generation: generation,
            currentText: """
            ~/dev
            hello
            Shift+Tab:mode | Ctrl+C:cancel | Ctrl+X:shortcuts
            Hello. How can I help you today?
            """
        )

        XCTAssertEqual(candidate?.resultText, "Hello. How can I help you today?")
    }

    func testOutputSummaryPrefersLatestResponseOverEarlierLongWarning() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(submittedText: "hello", baselineText: "~/dev")
        let generation = try XCTUnwrap(tracker.recordOutput(byteCount: 300))

        let candidate = tracker.completeIfCurrent(
            generation: generation,
            currentText: """
            A very long warning that was printed before the response and should not win by length alone.
            › hello
            Hello. Ready when you are—tell me what you want to do.
            """
        )

        XCTAssertEqual(candidate?.resultText, "Hello. Ready when you are—tell me what you want to do.")
    }

    func testOutputSummaryIgnoresShortDurationStatusAfterResponse() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(submittedText: "hello", baselineText: "~/dev")
        let generation = try XCTUnwrap(tracker.recordOutput(byteCount: 300))

        let candidate = tracker.completeIfCurrent(
            generation: generation,
            currentText: """
            Hello. How can I help you today?
            Finished in 2.4s.
            """
        )

        XCTAssertEqual(candidate?.resultText, "Hello. How can I help you today?")
    }

    func testOutputSummaryPreservesShortActualResponse() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(submittedText: "hi", baselineText: "~/terminal\n› hi")
        let generation = try XCTUnwrap(tracker.recordOutput(byteCount: 100))

        let candidate = tracker.completeIfCurrent(
            generation: generation,
            currentText: "~/terminal\n› hi\nHi."
        )

        XCTAssertEqual(candidate?.resultText, "Hi.")
    }

    func testOutputSummaryUsesResponseInsteadOfLaterTUIStatusLine() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(
            submittedText: "hi",
            baselineText: "gpt-5.3-codex-spark high · ~/dev · Ready\n› hi"
        )
        let generation = try XCTUnwrap(tracker.recordOutput(byteCount: 300))

        let candidate = tracker.completeIfCurrent(
            generation: generation,
            currentText: """
            › hi
            Hello. What would you like to work on today?
            › Use /skills to list available skills
            gpt-5.3-codex-spark high · ~/dev · gpt-5.3-codex-spark · high · Ready · Workspace · Context 94%
            """
        )

        XCTAssertEqual(candidate?.resultText, "Hello. What would you like to work on today?")
    }

    func testOutputSummaryPreservesWrappedResponseAsOneNotificationBody() throws {
        var tracker = TerminalActivityCompletionTracker()
        tracker.begin(submittedText: "hello, i am fine", baselineText: "› hello, i am fine")
        let generation = try XCTUnwrap(tracker.recordOutput(byteCount: 400))

        let candidate = tracker.completeIfCurrent(
            generation: generation,
            currentText: """
            › hello, i am fine
            Understood. I'm ready when you are. If you want, I can start by checking your repo status or jump straight to a small improvement
            you have in mind.
            › Use /skills to list available skills
            gpt-5.3-codex-spark high · ~/dev · Working · Workspace · Context 94%
            """
        )

        XCTAssertEqual(
            candidate?.resultText,
            "Understood. I'm ready when you are. If you want, I can start by checking your repo status or jump straight to a small improvement you have in mind."
        )
    }
}
