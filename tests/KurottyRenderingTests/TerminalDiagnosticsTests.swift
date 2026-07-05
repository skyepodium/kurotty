import Foundation
import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class TerminalDiagnosticsTests: XCTestCase {
    func testInputClientDebugLoggingUsesMetadataOnly() throws {
        let source = try terminalTextInputRouterSource()

        XCTAssertTrue(source.contains("source=\\(source)"))
        XCTAssertTrue(source.contains("utf8ByteCount=\\(text.utf8.count)"))
        XCTAssertTrue(source.contains("characterCount=\\(text.count)"))
        XCTAssertTrue(source.contains("replacement=\\(NSStringFromRange(replacementRange))"))
        XCTAssertTrue(source.contains("selected=\\(NSStringFromRange(selectedRange))"))
        XCTAssertTrue(source.contains("keyCode=\\(event.keyCode)"))
        XCTAssertTrue(source.contains("flags=\\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)"))

        XCTAssertFalse(source.contains("String(format: \"%02X\""))
        XCTAssertFalse(source.contains("debugText("))
        XCTAssertFalse(source.contains("chars=\\("))
        XCTAssertFalse(source.contains("ignoring=\\("))
        XCTAssertFalse(source.contains("text=\\("))
    }

    func testNotificationSummarySkipsMetadataStatusLines() {
        let statusLine = "gpt-5.5 medium · ~/dev/kurotty · gpt-5.5 · medium · kurotty · develop · No changes · Ready · Workspace · Ask fo..."
        let answerLine = "• 안녕하세요. 무엇을 도와드릴까요?"

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "────────────────────────────────────────",
                answerLine,
                statusLine,
            ]),
            answerLine
        )
    }

    func testNotificationSummarySkipsCodexContextStatusLines() {
        let answerLine = "작업 완료: 알림 본문은 마지막 완료 요약을 보여줍니다."
        let statusLine = "gpt-5.5 medium · ~/dev · gpt-5.5 · medium · Ready · Full Access · never · Context 100% left · Context 0% used · 5h 7..."

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                answerLine,
                statusLine,
            ]),
            answerLine
        )
    }

    func testNotificationSummarySkipsPromptPlaceholderLines() {
        let answerLine = "원인 잡아서 고쳤습니다."

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "────────────────────────────────────────",
                answerLine,
                "› Explain this codebase",
            ]),
            answerLine
        )
    }

    func testNotificationSummarySkipsShellPromptLines() {
        let answerLine = "작업 완료: 알림 본문은 이 줄이어야 합니다."
        let promptLine = "\(NSUserName()) ~/dev kurotty"

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                answerLine,
                promptLine,
            ]),
            answerLine
        )
    }

    func testNotificationSummaryDoesNotReturnOnlyShellPrompt() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "\(NSUserName()) ~/dev",
                "\(NSUserName()) /Users/\(NSUserName())/dev/kurotty",
            ])
        )
    }

    func testNotificationSummaryDoesNotReturnOnlyPromptPlaceholder() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "› Explain this codebase",
                "> Ask anything",
            ])
        )
    }

    func testNotificationSummaryDoesNotReturnOnlyStatusOrDecoration() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "────────────────────────────────────────",
                "gpt-5.5 medium · ~/dev/kurotty · gpt-5.5 · medium · kurotty · develop · No changes · Ready · Workspace",
            ])
        )
    }

    func testNotificationSummarySkipsSeparatorVariantsAfterAnswer() {
        let answerLine = "안녕. 오늘은 Kurotty 작업 도와줄까, 아니면 다른 얘기할까?"

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                answerLine,
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━…",
                "⎯⎯⎯⎯⎯⎯⎯⎯",
                "╭────────────────────────╮",
            ]),
            answerLine
        )
    }

    func testNotificationSummaryUsesLatestAnswerFromOutputText() {
        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulLine(fromOutputText: """
            \u{1b}[2m•\u{1b}[0m 안녕하세요. 무엇을 도와드릴까요?

            ────────────────────────────────────────

            › 아녕

            • 안녕! 편하게 말씀해 주세요.
            """),
            "• 안녕! 편하게 말씀해 주세요."
        )
    }

    func testNotificationSummaryUsesLatestMeaningfulOutputBlock() {
        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulText(fromOutputText: """
            build step 1 passed
            build step 2 passed
            tests failed: 2 regressions

            ────────────────────────────────────────

            \(NSUserName()) ~/dev/kurotty
            """),
            """
            build step 1 passed
            build step 2 passed
            tests failed: 2 regressions
            """
        )
    }

    func testNotificationSummaryUsesLatestCodexAnswerBlockInsteadOfSubmittedPrompt() {
        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulText(fromOutputText: """
            Tip: Use /side to start a side conversation in a temporary fork

            • You have 4 usage limit resets available. Run /usage to use one.

            ⚠ failed to parse hooks config /Users/skyepodium/.codex/hooks.json
              column 9

            › 안녕하세요

            • superpowers:using-superpowers 지침을 먼저 확인한 뒤, 간단히 응답

            • Explored
              └ Read SKILL.md (superpowers:using-superpowers skill)

            • 안녕하세요. 무엇을 도와드릴까요?

            ────────────────────────────────────────

            › Summarize recent commits
            """),
            "• 안녕하세요. 무엇을 도와드릴까요?"
        )
    }

    func testNotificationSummaryRemovesInlineCodexStatusFragments() {
        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulText(fromOutputText: """
            • 안녕하세요. 무엇을 도와드릴까요?•Work55
            """),
            "• 안녕하세요. 무엇을 도와드릴까요?"
        )

        XCTAssertEqual(
            TerminalNotificationSummary.latestMeaningfulText(fromOutputText: """
            • 안녕하세요. 무엇을 도와드릴까요? · Ready · Workspace
            """),
            "• 안녕하세요. 무엇을 도와드릴까요?"
        )
    }

    func testNotificationSummarySkipsUsageStatusFromOutputText() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromOutputText: """
            Weekly limit:
            [██████████████████████████████]
            100% left (resets 05:23 on 8 Jul) |
            """)
        )
    }

    func testNotificationSummaryDoesNotReturnOnlySeparatorVariants() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromVisibleLines: [
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━…",
                "⎯⎯⎯⎯⎯⎯⎯⎯",
                "╰────────────────────────╯",
                "••••••••••",
            ])
        )
    }

    func testNotificationSummaryDoesNotReturnOnlyShellPercentPrompt() {
        XCTAssertNil(
            TerminalNotificationSummary.latestMeaningfulLine(fromOutputText: """
            %
            """)
        )
    }

    func testBackgroundTaskTrackingTreatsInteractiveTuiInputAsTerminalAlert() {
        XCTAssertEqual(
            TerminalBackgroundTaskTrackingPolicy.trackingDecision(
                for: "hello",
                visibleText: """
                › hello

                • I'll load the required startup skill, then respond normally.

                • Explored
                  └ Read SKILL.md (superpowers:using-superpowers skill)

                • Hello. How can I help?

                › Summarize recent commits
                gpt-5.5 medium · ~/dev · gpt-5.5 · medium · Ready · Workspace · Ask for approval
                """
            ),
            .terminalAlert
        )
    }

    func testBackgroundTaskTrackingDoesNotPromoteInteractiveTuiInputToTaskCompletion() {
        XCTAssertNotEqual(
            TerminalBackgroundTaskTrackingPolicy.trackingDecision(
                for: "hello",
                visibleText: """
                › hello

                • I'll load the required startup skill, then respond normally.

                • Explored
                  └ Read SKILL.md (superpowers:using-superpowers skill)

                • Hello. How can I help?

                › Summarize recent commits
                gpt-5.5 medium · ~/dev · gpt-5.5 · medium · Ready · Workspace · Ask for approval
                """
            ),
            .generic
        )
    }

    func testBackgroundTaskTrackingAllowsShellCommandsOutsideInteractiveTui() {
        XCTAssertTrue(
            TerminalBackgroundTaskTrackingPolicy.shouldTrackSubmittedInput(
                "swift test",
                visibleText: """
                skyepodium ~/dev/kurotty
                """
            )
        )
    }

    func testBackgroundTaskTrackingRejectsInteractiveCodexCommandLaunch() {
        XCTAssertFalse(
            TerminalBackgroundTaskTrackingPolicy.shouldTrackSubmittedInput(
                "codex",
                visibleText: """
                \(NSUserName()) ~/dev/kurotty
                """
            )
        )

        XCTAssertTrue(
            TerminalBackgroundTaskTrackingPolicy.shouldTrackSubmittedInput(
                "codex exec summarize recent commits",
                visibleText: """
                \(NSUserName()) ~/dev/kurotty
                """
            )
        )
    }

    func testBackgroundTaskTrackingTreatsInteractiveTuiPromptsAsTerminalAlert() {
        XCTAssertEqual(
            TerminalBackgroundTaskTrackingPolicy.trackingDecision(
                for: "hello",
                visibleText: """
                › hello
                gpt-5.5 medium · ~/dev · gpt-5.5 · medium · Ready · Workspace · Ask for approval
                """
            ),
            .terminalAlert
        )
    }

    func testBackgroundTaskTrackingTreatsAllInteractiveTuiPromptsAsTerminalAlerts() {
        XCTAssertEqual(
            TerminalBackgroundTaskTrackingPolicy.trackingDecision(
                for: "Summarize recent commits",
                visibleText: """
                › Summarize recent commits
                gpt-5.5 medium · ~/dev · gpt-5.5 · medium · Ready · Workspace · Ask for approval
                """
            ),
            .terminalAlert
        )
    }

    func testBackgroundTaskTrackingAllowsShellCommandAfterCodexTranscriptWhenShellPromptIsCurrent() {
        XCTAssertTrue(
            TerminalBackgroundTaskTrackingPolicy.shouldTrackSubmittedInput(
                "ls",
                visibleText: """
                › hello

                • Hello. How can I help?

                \(NSUserName()) ~/dev/kurotty
                """
            )
        )
    }

    func testCodexNotificationContentUsesSpecificTitleAndMeaningfulBody() {
        let content = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "codex exec create pr",
            outputText: """
            develop → main PR 올렸습니다.

            PR: https://github.com/skyepodium/kurotty/pull/57
            상태: `OPEN`, `MERGEABLE`

            %
            """
        )

        XCTAssertEqual(content.title, "Codex task finished")
        XCTAssertEqual(content.subtitle, "codex exec create pr")
        XCTAssertEqual(
            content.body,
            "develop → main PR 올렸습니다.\n\nPR: https://github.com/skyepodium/kurotty/pull/57\n상태: `OPEN`, `MERGEABLE`"
        )
    }

    func testGenericBackgroundNotificationDoesNotPromoteInteractiveTuiOutputToCodexCompletion() {
        let content = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "hello",
            outputText: """
            \u{1b}[38;2;200;169;238;49mAsk for approval

            • I'll load the required startup skill first, then I'll answer normally.

            • Explored
              └ Read SKILL.md (superpowers:using-superpowers skill)

            ────────────────────────────────────────

            • Hello. What are we working on?\u{1b}[38;2;200;169;238;49mWorki55

            gpt-5.5 medium · ~/dev · gpt-5.5 · medium · Ready · Workspace · Ask for approval · Context 99% left
            """
        )

        XCTAssertEqual(content.title, "Task finished")
        XCTAssertEqual(content.subtitle, "hello")
        XCTAssertEqual(content.body, "Hello. What are we working on?")
        XCTAssertFalse(content.body.contains("38;2"))
        XCTAssertFalse(content.body.contains("Ask for approval"))
        XCTAssertFalse(content.body.contains("Explored"))
        XCTAssertFalse(content.body.contains("SKILL.md"))
        XCTAssertFalse(content.body.contains("Worki55"))
        XCTAssertFalse(content.body.contains("gpt-5.5"))
    }

    func testTerminalAlertContentUsesIterm2StyleSessionOutputMessage() {
        let content = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "hello",
            outputText: """
            › hello

            • I’m loading the required startup skill, then I’ll
              answer normally.

            • Explored
              └ Read SKILL.md (superpowers:using-superpowers skill)

            ────────────────────────────────────

            • Hi. What would you like to work on?

            gpt-5.5 medium · ~/dev · Ready · Workspace · Ask for approval
            """,
            source: .terminalAlert(sessionDescription: "dev (codex)", tabIndex: 1)
        )

        XCTAssertEqual(content.title, "Alert")
        XCTAssertEqual(content.subtitle, "")
        XCTAssertEqual(content.body, "Session dev (codex) #1: Hi. What would you like to work on?")
        XCTAssertFalse(content.body.contains("hello"))
        XCTAssertFalse(content.body.contains("Explored"))
        XCTAssertFalse(content.body.contains("SKILL.md"))
        XCTAssertFalse(content.body.contains("gpt-5.5"))
    }

    func testTerminalAlertContentRemovesTrailingWorkingRepaintStatus() {
        let content = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "hello",
            outputText: """
            › hello

            • Hi. What would you like to work on?\u{1b}[38;2;200;169;238mWorking
            """,
            source: .terminalAlert(sessionDescription: "dev", tabIndex: 1)
        )

        XCTAssertEqual(content.body, "Session dev #1: Hi. What would you like to work on?")
        XCTAssertFalse(content.body.contains("Working"))
    }

    func testTerminalAlertContentRemovesShortTrailingStatusRepaintRemainder() {
        let content = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "hello",
            outputText: """
            › hello

            • Hello. I’m in /Users/skyepodium/dev and ready to work.\u{1b}[38;2;200;169;238mW5
            """,
            source: .terminalAlert(sessionDescription: "dev", tabIndex: 1)
        )

        XCTAssertEqual(
            content.body,
            "Session dev #1: Hello. I’m in /Users/skyepodium/dev and ready to work."
        )
        XCTAssertFalse(content.body.contains("W5"))
    }

    func testTerminalAlertContentAcceptsBulletWithoutFollowingSpace() {
        let content = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "안녕",
            outputText: """
            ›안녕

            2026I2

            •안녕하세요. 무엇을 도와드릴까요?
            """,
            source: .terminalAlert(sessionDescription: "dev", tabIndex: 1)
        )

        XCTAssertEqual(content.body, "Session dev #1: 안녕하세요. 무엇을 도와드릴까요?")
        XCTAssertFalse(content.body.contains("2026I2"))
        XCTAssertFalse(content.body.contains("›안녕"))
    }

    func testTerminalAlertContentAcceptsSubsequentNoSpaceKoreanAndEnglishAnswers() {
        let korean = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "안녕",
            outputText: """
            ›안녕

            •안녕하세요.무엇을  도와드릴까요?
            """,
            source: .terminalAlert(sessionDescription: "dev", tabIndex: 1)
        )
        XCTAssertEqual(korean.body, "Session dev #1: 안녕하세요.무엇을  도와드릴까요?")

        let english = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "what is your name?",
            outputText: """
            › what is your name?

            • My name is Codex.
            """,
            source: .terminalAlert(sessionDescription: "dev", tabIndex: 1)
        )
        XCTAssertEqual(english.body, "Session dev #1: My name is Codex.")
    }

    func testTerminalAlertIsNotDeliverableWhenOnlyControlFragmentsAreAvailable() {
        let content = TerminalBackgroundTaskNotificationContent.makeIfDeliverable(
            submittedCommand: "안녕",
            outputText: """
            ›안녕

            2026I2
            """,
            source: .terminalAlert(sessionDescription: "dev", tabIndex: 1)
        )

        XCTAssertNil(content)
    }

    func testTerminalAlertIdleKeepsTrackingWhenOnlyControlFragmentsAreAvailable() throws {
        let source = try terminalSurfaceViewSource()
        guard let start = source.range(of: "private func notifyBackgroundTaskIfIdle")?.lowerBound,
              let end = source.range(of: "private func backgroundTaskNotificationContent")?.lowerBound else {
            XCTFail("missing background task idle source region")
            return
        }
        let idleSource = String(source[start..<end])

        XCTAssertTrue(idleSource.contains("let outputText = backgroundTaskOutputText"))
        XCTAssertNotNil(idleSource.range(
            of: #"guard let content = backgroundTaskNotificationContent\(outputText: outputText\) else \{[\s\S]*?backgroundTaskHasOutput = false\s+backgroundTaskNotificationWorkItem = nil\s+return\s+\}"#,
            options: .regularExpression
        ))
        XCTAssertFalse(idleSource.contains("""
        backgroundTaskInputSequence = nil
        backgroundTaskHasOutput = false
        backgroundTaskNotificationWorkItem = nil
        let outputText = backgroundTaskOutputText
        backgroundTaskOutputText = ""
        guard let content = backgroundTaskNotificationContent(outputText: outputText)
        """))
    }

    func testExplicitCodexCommandCanUseCodexCompletionTitle() {
        let content = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "codex exec inspect tree",
            outputText: """
            • I checked the working tree and found no changes.

            gpt-5.5 medium · ~/dev · Ready · Workspace · Context 99% left
            """
        )

        XCTAssertEqual(content.title, "Codex task finished")
        XCTAssertEqual(content.subtitle, "codex exec inspect tree")
        XCTAssertEqual(content.body, "I checked the working tree and found no changes.")
    }

    func testExplicitCodexCommandUsesPromptAndNeedsInputStatus() {
        let content = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "codex exec summarize recent commits",
            outputText: """
            • I found three recent commits and need approval to inspect the diff.

            gpt-5.5 medium · ~/dev · Ready · Workspace · Ask for approval · Context 99% left
            """
        )

        XCTAssertEqual(content.title, "Codex needs input")
        XCTAssertEqual(content.subtitle, "codex exec summarize recent commits")
        XCTAssertEqual(content.body, "I found three recent commits and need approval to inspect the diff.")
    }

    func testExplicitCodexCommandDoesNotTreatApprovalPolicyStatusAsNeedsInput() {
        let content = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "codex exec summarize recent commits",
            outputText: """
            • I found three recent commits.

            gpt-5.5 medium · ~/dev · Ready · Workspace · Ask for approval · Context 99% left
            """
        )

        XCTAssertEqual(content.title, "Codex task finished")
        XCTAssertEqual(content.subtitle, "codex exec summarize recent commits")
        XCTAssertEqual(content.body, "I found three recent commits.")
    }

    func testCodexNotificationContentDetectsFailureAndInputRequired() {
        let failed = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "codex exec release",
            outputText: "error: release build failed\nSee logs for details."
        )
        XCTAssertEqual(failed.title, "Codex task failed")
        XCTAssertEqual(failed.subtitle, "codex exec release")
        XCTAssertEqual(failed.body, "error: release build failed\nSee logs for details.")

        let needsInput = TerminalBackgroundTaskNotificationContent.make(
            submittedCommand: "codex exec release",
            outputText: "Approval required: allow shell command?\n❯ Yes\n  No"
        )
        XCTAssertEqual(needsInput.title, "Codex needs input")
        XCTAssertEqual(needsInput.subtitle, "codex exec release")
        XCTAssertEqual(needsInput.body, "Approval required: allow shell command?\n❯ Yes\n  No")
    }

    func testNotificationLogMetadataDoesNotExposeTitleOrBody() {
        let metadata = TerminalNotificationLogMetadata(
            identifierPrefix: "dev.kurotty.terminal.osc9",
            title: "Build finished",
            body: "secret terminal output /Users/example/private"
        )

        XCTAssertEqual(metadata.identifierPrefix, "dev.kurotty.terminal.osc9")
        XCTAssertEqual(metadata.titleLength, 14)
        XCTAssertEqual(metadata.bodyLength, 45)
        XCTAssertFalse(metadata.description.contains("Build finished"))
        XCTAssertFalse(metadata.description.contains("secret terminal output"))
        XCTAssertFalse(metadata.description.contains("/Users/example/private"))
    }

    func testRawPtyLogMetadataDoesNotExposeBytesOrDecodedText() {
        let data = Data("token=secret\n".utf8)
        let metadata = TerminalRawPtyLogMetadata(data: data)

        XCTAssertEqual(metadata.byteCount, data.count)
        XCTAssertFalse(metadata.description.contains("token=secret"))
        XCTAssertFalse(metadata.description.contains("746F6B656E"))
    }

    func testCoreCompatibilityDiagnosticDescribesStateSourcesWithoutTerminalContent() {
        let diagnostic = TerminalCoreCompatibilityDiagnostic(
            bridge: .zigCore,
            pty: .swiftScaffold,
            parser: .swiftScaffold,
            screen: .swiftScaffold,
            render: .swiftScaffold
        )

        XCTAssertEqual(diagnostic.bridge, .zigCore)
        XCTAssertEqual(diagnostic.screen, .swiftScaffold)
        XCTAssertEqual(diagnostic.render, .swiftScaffold)
        XCTAssertTrue(diagnostic.description.contains("bridge=zig-core"))
        XCTAssertTrue(diagnostic.description.contains("pty=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("parser=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("screen=swift-scaffold"))
        XCTAssertTrue(diagnostic.description.contains("render=swift-scaffold"))
        XCTAssertFalse(diagnostic.description.contains("token=secret"))
        XCTAssertFalse(diagnostic.description.contains("terminal text"))
    }

    func testTraceCorrelationReportRequiresOrderedPipelineStages() {
        let traceID = TerminalEventTraceID("diagnostic-pipeline")
        let completeSummary = TerminalEventLedger.TraceSummary(
            traceID: traceID,
            eventCount: 4,
            kindCounts: [
                .ptyRead: 1,
                .parserEvent: 1,
                .screenMutation: 1,
                .renderFrame: 1,
            ],
            ptyReadByteCount: 5,
            parserEventByteCount: 5,
            screenMutationCount: 1,
            renderFrameCount: 1,
            dirtyRegionCount: 2,
            fullRedrawCount: 0,
            firstSequence: 0,
            lastSequence: 3,
            droppedEventCount: 0
        )
        let outOfOrder = TerminalTraceCorrelationReport(
            eventSummary: completeSummary,
            stageSequence: [.ptyRead, .screenMutation, .parserEvent, .renderFrame]
        )

        XCTAssertFalse(outOfOrder.hasCompleteRenderPath)
        XCTAssertEqual(
            outOfOrder.description,
            "trace=diagnostic-pipeline path=ptyRead>screenMutation>parserEvent>renderFrame complete=false resize=unavailable issues=0 ptyBytes=5 parserBytes=5 screenMutations=1 renderFrames=1 dirtyRegions=2 fullRedraws=0 droppedEvents=0"
        )
        XCTAssertFalse(outOfOrder.description.contains("token=secret"))
    }

    func testTraceCorrelationReportExposesProductionTimelineSummary() {
        let traceID = TerminalEventTraceID("timeline-pipeline")
        let summary = TerminalEventLedger.TraceSummary(
            traceID: traceID,
            eventCount: 4,
            kindCounts: [
                .ptyRead: 1,
                .parserEvent: 1,
                .screenMutation: 1,
                .renderFrame: 1,
            ],
            ptyReadByteCount: 11,
            parserEventByteCount: 5,
            screenMutationCount: 1,
            renderFrameCount: 1,
            dirtyRegionCount: 3,
            fullRedrawCount: 1,
            firstSequence: 12,
            lastSequence: 15,
            droppedEventCount: 2
        )
        let resize = TerminalResizeCycleSnapshot(
            traceID: "timeline-pipeline",
            source: "runtime-resize",
            viewportSize: TerminalFrameSize(width: 800, height: 400),
            cellSize: TerminalFrameSize(width: 8, height: 16),
            ptyColumns: 100,
            ptyRows: 25,
            screenColumns: 100,
            screenRows: 24,
            rendererColumns: 100,
            rendererRows: 25
        )
        let report = TerminalTraceCorrelationReport(
            eventSummary: summary,
            stageSequence: [.ptyRead, .parserEvent, .screenMutation, .renderFrame],
            resizeSnapshot: resize
        )

        let timeline = report.timelineSummary

        XCTAssertEqual(timeline.traceID, traceID)
        XCTAssertEqual(timeline.stagePath, "ptyRead>parserEvent>screenMutation>renderFrame")
        XCTAssertEqual(timeline.firstSequence, 12)
        XCTAssertEqual(timeline.lastSequence, 15)
        XCTAssertEqual(timeline.resizeIssueCount, 1)
        XCTAssertTrue(timeline.hasCompleteRenderPath)
        XCTAssertEqual(
            timeline.description,
            "trace=timeline-pipeline stages=ptyRead>parserEvent>screenMutation>renderFrame complete=true sequenceRange=12...15 events=4 droppedEvents=2 resizeIssues=1 ptyBytes=11 parserBytes=5 screenMutations=1 renderFrames=1 dirtyRegions=3 fullRedraws=1"
        )
        XCTAssertFalse(timeline.description.contains("CSI"))
        XCTAssertFalse(timeline.description.contains("secret"))
    }

    func testTraceSourceOfTruthDiagnosticExposesMissingStagesWithoutPayloadText() {
        let traceID = TerminalEventTraceID("missing-stage-pipeline")
        let summary = TerminalEventLedger.TraceSummary(
            traceID: traceID,
            eventCount: 2,
            kindCounts: [
                .ptyRead: 1,
                .screenMutation: 1,
            ],
            ptyReadByteCount: 12,
            parserEventByteCount: 0,
            screenMutationCount: 1,
            renderFrameCount: 0,
            dirtyRegionCount: 0,
            fullRedrawCount: 0,
            firstSequence: 4,
            lastSequence: 5,
            droppedEventCount: 0
        )
        let report = TerminalTraceCorrelationReport(
            eventSummary: summary,
            stageSequence: [.ptyRead, .screenMutation]
        )

        let diagnostic = report.sourceOfTruthDiagnostic

        XCTAssertFalse(diagnostic.isSourceOfTruthComplete)
        XCTAssertEqual(diagnostic.missingStages, [.parserEvent, .renderFrame])
        XCTAssertEqual(diagnostic.missingStageNames, ["parserEvent", "renderFrame"])
        XCTAssertEqual(
            diagnostic.description,
            "trace=missing-stage-pipeline sourceOfTruthComplete=false completeRenderPath=false stages=ptyRead>screenMutation missingStages=parserEvent,renderFrame events=2 droppedEvents=0 ptyBytes=12 parserBytes=0 screenMutations=1 renderFrames=0"
        )
        XCTAssertFalse(diagnostic.description.contains("CSI"))
        XCTAssertFalse(diagnostic.description.contains("token=secret"))
    }

    func testTraceSourceOfTruthDiagnosticMarksCompleteOrderedUndroppedTrace() {
        let traceID = TerminalEventTraceID("complete-live-fixture")
        let summary = TerminalEventLedger.TraceSummary(
            traceID: traceID,
            eventCount: 4,
            kindCounts: [
                .ptyRead: 1,
                .parserEvent: 1,
                .screenMutation: 1,
                .renderFrame: 1,
            ],
            ptyReadByteCount: 8,
            parserEventByteCount: 8,
            screenMutationCount: 1,
            renderFrameCount: 1,
            dirtyRegionCount: 1,
            fullRedrawCount: 0,
            firstSequence: 0,
            lastSequence: 3,
            droppedEventCount: 0
        )
        let report = TerminalTraceCorrelationReport(
            eventSummary: summary,
            stageSequence: [.ptyRead, .parserEvent, .screenMutation, .renderFrame]
        )

        let diagnostic = report.sourceOfTruthDiagnostic

        XCTAssertTrue(diagnostic.isSourceOfTruthComplete)
        XCTAssertTrue(diagnostic.missingStages.isEmpty)
        XCTAssertEqual(diagnostic.missingStageNames, [])
        XCTAssertTrue(diagnostic.description.contains("sourceOfTruthComplete=true"))
        XCTAssertTrue(diagnostic.description.contains("missingStages=none"))
    }

    func testCoreBridgeReportsSwiftScaffoldDiagnosticWhenZigCoreIsUnavailable() {
        let bridge = CoreBridge(cols: 2, rows: 1, loadSymbols: false)

        XCTAssertEqual(bridge.compatibilityDiagnostic.bridge, .swiftScaffold)
        XCTAssertEqual(bridge.compatibilityDiagnostic.screen, .swiftScaffold)
        XCTAssertEqual(bridge.compatibilityDiagnostic.render, .swiftScaffold)
        XCTAssertTrue(bridge.compatibilityDiagnostic.description.contains("bridge=swift-scaffold"))
        XCTAssertTrue(bridge.compatibilityDiagnostic.description.contains("screen=swift-scaffold"))
    }

    func testTerminalCoreFactoryExposesCompatibilityDiagnosticForTypeErasedCore() {
        let core: any TerminalCore = CoreBridge(cols: 2, rows: 1, loadSymbols: false)
        let diagnostic = TerminalCoreFactory.compatibilityDiagnostic(for: core)

        XCTAssertEqual(diagnostic.bridge, .swiftScaffold)
        XCTAssertEqual(diagnostic.pty, .swiftScaffold)
        XCTAssertEqual(diagnostic.parser, .swiftScaffold)
        XCTAssertEqual(diagnostic.screen, .swiftScaffold)
        XCTAssertEqual(diagnostic.render, .swiftScaffold)
    }

    func testTerminalCoreFactoryReportsUnknownForNonDiagnosingCore() {
        let core: any TerminalCore = NonDiagnosingTerminalCore()
        let diagnostic = TerminalCoreFactory.compatibilityDiagnostic(for: core)

        XCTAssertEqual(diagnostic.bridge, .unknown)
        XCTAssertEqual(diagnostic.pty, .unknown)
        XCTAssertEqual(diagnostic.parser, .unknown)
        XCTAssertEqual(diagnostic.screen, .unknown)
        XCTAssertEqual(diagnostic.render, .unknown)
    }

    func testResizeTraceClampsRequestedDimensionsToPtyWinsizeRange() {
        let trace = TerminalResizeTrace(
            requestedColumns: 0,
            requestedRows: 70_000,
            cellSize: nil,
            viewSize: nil,
            ioctlResult: 0,
            ioctlErrno: nil,
            didSendSIGWINCH: true
        )

        XCTAssertEqual(trace.requestedColumns, 0)
        XCTAssertEqual(trace.requestedRows, 70_000)
        XCTAssertEqual(trace.clampedColumns, 1)
        XCTAssertEqual(trace.clampedRows, Int(UInt16.max))
        XCTAssertTrue(trace.description.contains("requested=0x70000"))
        XCTAssertTrue(trace.description.contains("clamped=1x65535"))
        XCTAssertTrue(trace.description.contains("sigwinch=sent"))
    }

    func testResizeTraceFormatsOptionalViewAndIoctlMetadataOnly() {
        let trace = TerminalResizeTrace(
            requestedColumns: 120,
            requestedRows: 40,
            cellSize: TerminalFrameSize(width: 9.25, height: 18.5),
            viewSize: TerminalFrameSize(width: 1110.0, height: 740.0),
            ioctlResult: -1,
            ioctlErrno: 25,
            didSendSIGWINCH: false
        )

        XCTAssertEqual(trace.clampedColumns, 120)
        XCTAssertEqual(trace.clampedRows, 40)
        XCTAssertTrue(trace.description.contains("requested=120x40"))
        XCTAssertTrue(trace.description.contains("clamped=120x40"))
        XCTAssertTrue(trace.description.contains("cell=9.25x18.50"))
        XCTAssertTrue(trace.description.contains("view=1110.00x740.00"))
        XCTAssertTrue(trace.description.contains("ioctl=-1 errno=25"))
        XCTAssertTrue(trace.description.contains("sigwinch=not-sent"))
        XCTAssertFalse(trace.description.contains("token="))
        XCTAssertFalse(trace.description.contains("/Users/"))
    }

    func testDarwinResizeLogsTraceMetadataWhenPtyLoggingIsEnabled() throws {
        let source = try shellSessionSource()

        XCTAssertTrue(source.contains("TerminalResizeTrace("))
        XCTAssertTrue(source.contains("UInt16(trace.clampedRows)"))
        XCTAssertTrue(source.contains("UInt16(trace.clampedColumns)"))
        XCTAssertTrue(source.contains("ioctlResult == -1 ? errno : nil"))
        XCTAssertTrue(source.contains("if DebugOptions.ptyLog"))
        XCTAssertTrue(source.contains("Kurotty PTY resize"))
        XCTAssertFalse(source.contains("UInt16(max(1, rows))"))
        XCTAssertFalse(source.contains("UInt16(max(1, columns))"))
    }

    func testTerminalSessionProtocolExposesMetadataOnlyRuntimeHooks() throws {
        let source = try terminalSessionSource()

        XCTAssertTrue(source.contains("var onRuntimeEvent: ((TerminalSessionRuntimeEvent) -> Void)? { get set }"))
        XCTAssertTrue(source.contains("var onResizeTrace: ((TerminalResizeTrace) -> Void)? { get set }"))
        XCTAssertTrue(source.contains("enum TerminalSessionRuntimeEvent"))
        XCTAssertTrue(source.contains("case ptyRead(TerminalRawPtyLogMetadata)"))
        XCTAssertFalse(source.contains("case ptyRead(Data)"))
    }

    func testDarwinPtyReadAndResizeEmitMetadataHooksWithoutDebugFlagGate() throws {
        let source = try shellSessionSource()

        XCTAssertTrue(source.contains("onRuntimeEvent?(.ptyRead(metadata))"))
        XCTAssertTrue(source.contains("onResizeTrace?(completedTrace)"))
        XCTAssertTrue(source.contains("onRawOutput?(chunk)"))
        XCTAssertTrue(source.contains("if DebugOptions.ptyLog"))
        XCTAssertLessThan(
            try XCTUnwrap(source.range(of: "onRuntimeEvent?(.ptyRead(metadata))")?.lowerBound),
            try XCTUnwrap(source.range(of: "pendingOutput.append(chunk)")?.lowerBound)
        )
        XCTAssertFalse(source.contains("onRuntimeEvent?(.ptyRead(chunk))"))
    }

    func testTerminalSurfaceWiresLiveTimelineAndResizeLedgersWithMetadataOnly() throws {
        let source = try terminalSurfaceViewSource()

        XCTAssertTrue(source.contains("private var runtimeEventLedger = TerminalEventLedger(capacity:"))
        XCTAssertTrue(source.contains("private var runtimeResizeLedger = TerminalResizeLedger(capacity:"))
        XCTAssertTrue(source.contains("shell.onRuntimeEvent ="))
        XCTAssertTrue(source.contains("runtimeEventLedger.recordPtyRead(traceID: traceID, byteCount: metadata.byteCount)"))
        XCTAssertTrue(source.contains("runtimeEventLedger.recordParserEvent("))
        XCTAssertTrue(source.contains("runtimeEventLedger.recordScreenMutation("))
        XCTAssertTrue(source.contains("runtimeEventLedger.recordRenderFrame("))
        XCTAssertTrue(source.contains("runtimeResizeLedger.record(TerminalResizeCycleSnapshot("))
        XCTAssertFalse(source.contains("runtimeEventLedger.recordPtyRead(traceID: traceID, data:"))
        XCTAssertFalse(source.contains("runtimeResizeLedger.record(text"))
    }

    func testStyleRunSummaryReportsRangesWithoutCellText() {
        let red = TerminalTextStyle(
            foreground: SIMD4<Float>(1, 0, 0, 1),
            background: SIMD4<Float>(0, 0, 0, 1)
        )
        let green = TerminalTextStyle(
            foreground: SIMD4<Float>(0, 1, 0, 1),
            background: SIMD4<Float>(0, 0, 0, 1)
        )

        let summary = TerminalScreenDiagnostics.styleRuns(
            for: [.default, .default, red, green],
            background: false
        )

        XCTAssertTrue(summary.contains("0-1"))
        XCTAssertTrue(summary.contains("2-2"))
        XCTAssertTrue(summary.contains("3-3"))
        XCTAssertFalse(summary.contains("secret"))
    }

    func testScreenDumpSourceDoesNotLogCellText() throws {
        let source = try terminalSurfaceViewSource()
        guard let start = source.range(of: "private func logScreenDumpIfNeeded")?.lowerBound,
              let end = source.range(of: "private func currentCursorCellRectInViewCoordinates")?.lowerBound else {
            XCTFail("missing screen dump source region")
            return
        }
        let screenDumpSource = String(source[start..<end])

        XCTAssertTrue(screenDumpSource.contains("occupiedCells="))
        XCTAssertTrue(screenDumpSource.contains("TerminalScreenDiagnostics.occupiedCellCount"))
        XCTAssertFalse(screenDumpSource.contains("text='%@'"))
        XCTAssertFalse(screenDumpSource.contains("String(row.map(\\.character))"))
    }

    func testOccupiedCellCountDoesNotExposeCellText() {
        let cells = [
            KurottyCore.TerminalScreenCell(character: "s"),
            KurottyCore.TerminalScreenCell(character: "e"),
            KurottyCore.TerminalScreenCell(character: "c"),
            KurottyCore.TerminalScreenCell(character: "r"),
            KurottyCore.TerminalScreenCell(character: "e"),
            KurottyCore.TerminalScreenCell(character: "t"),
            KurottyCore.TerminalScreenCell(character: " "),
        ]

        XCTAssertEqual(TerminalScreenDiagnostics.occupiedCellCount(in: cells), 6)
    }
}

private final class NonDiagnosingTerminalCore: TerminalCore {
    func feed(_ text: String) {}
    func recordKeyEvent() {}
    func recordFramePresented() {}
    func beginFrame(visibleCells: UInt32) -> UInt32 { visibleCells }
    func endFrame() {}
    func lastLatencyMicros() -> UInt64 { 0 }
    func resize(cols: UInt32, rows: UInt32) {}
    func cell(row: UInt32, col: UInt32) -> UInt8 { 0 }
    func copyRow(_ row: UInt32, into buffer: inout [UInt8]) -> Int { 0 }
}

private func terminalTextInputRouterSource() throws -> String {
    try String(
        contentsOf: sourceRoot()
            .appendingPathComponent("Sources/KurottyApp/TerminalTextInputRouter.swift"),
        encoding: .utf8
    )
}

private func terminalSurfaceViewSource() throws -> String {
    try String(
        contentsOf: sourceRoot()
            .appendingPathComponent("Sources/KurottyApp/TerminalSurfaceView.swift"),
        encoding: .utf8
    )
}

private func shellSessionSource() throws -> String {
    try String(
        contentsOf: sourceRoot()
            .appendingPathComponent("Sources/KurottyApp/ShellSession.swift"),
        encoding: .utf8
    )
}

private func terminalSessionSource() throws -> String {
    try String(
        contentsOf: sourceRoot()
            .appendingPathComponent("Sources/KurottyApp/TerminalSession.swift"),
        encoding: .utf8
    )
}

private func sourceRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url
}
