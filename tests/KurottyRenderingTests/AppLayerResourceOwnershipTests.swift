import Foundation
import XCTest
@testable import KurottyApp

/// Regression coverage for app-layer resource-ownership fixes: file
/// descriptors closed exactly once, diagnostics maps that stay bounded, and
/// child-process pipes that cannot wedge their owning queue.
final class AppLayerResourceOwnershipTests: XCTestCase {
    private enum Timeout {
        static let descriptorCloseSeconds: TimeInterval = 5
        static let gitCollectSeconds: TimeInterval = 10
    }

    // MARK: AgentSessionTranscriptWatcher descriptor ownership

    /// The watcher's directory descriptor is owned by the dispatch source's
    /// cancel handler and must be closed exactly once. Before the fix, deinit
    /// closed the stored descriptor number a second time after `stop()` had
    /// already closed it through the cancel handler; if the process had
    /// recycled that number, an unrelated descriptor died. The test occupies
    /// the freed number deliberately and proves dealloc leaves it alone.
    func testWatcherDeallocDoesNotCloseRecycledDescriptorAfterStop() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-fd-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent("transcript.jsonl")

        var watcher: AgentSessionTranscriptWatcher? = AgentSessionTranscriptWatcher(
            fileURL: fileURL,
            onChange: {}
        )
        guard watcher?.start() == true else {
            throw XCTSkip("native directory watch unavailable on this filesystem")
        }
        let watchedDescriptor = try XCTUnwrap(watcher?.nativeWatchDescriptorForTesting)
        XCTAssertGreaterThanOrEqual(watchedDescriptor, 0)

        watcher?.stop()

        // The cancel handler closes the descriptor asynchronously on the
        // watcher's queue; wait until the number is actually free.
        let deadline = Date().addingTimeInterval(Timeout.descriptorCloseSeconds)
        while fcntl(watchedDescriptor, F_GETFD) != -1, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertEqual(
            fcntl(watchedDescriptor, F_GETFD),
            -1,
            "stop() must close the directory descriptor via the cancel handler"
        )

        // Recycle the freed number, exactly as the kernel would for the next
        // open() anywhere in the process.
        let devNull = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(devNull, 0)
        defer { close(devNull) }
        XCTAssertEqual(dup2(devNull, watchedDescriptor), watchedDescriptor)
        defer { close(watchedDescriptor) }

        // Dealloc after stop() must not close the recycled number again.
        watcher = nil
        XCTAssertNotEqual(
            fcntl(watchedDescriptor, F_GETFD),
            -1,
            "deinit closed a descriptor number it no longer owns"
        )
    }

    // MARK: TerminalEventLedger bounded per-trace tracking

    /// Trace IDs are unique per PTY read, so per-trace dropped counts must be
    /// evicted with the trace. Before the fix the per-trace map kept one entry
    /// per trace ID ever dropped, growing monotonically for the lifetime of
    /// the surface.
    func testDroppedTraceTrackingStaysBoundedAcrossManyUniqueTraces() {
        let capacity = 2
        let uniqueTraceCount = 1_000
        var ledger = TerminalEventLedger(capacity: capacity)

        for index in 0..<uniqueTraceCount {
            ledger.recordPtyRead(traceID: TerminalEventTraceID("pty-read-\(index)"), byteCount: 1)
        }

        XCTAssertEqual(ledger.diagnostics.droppedEventCount, uniqueTraceCount - capacity)
        XCTAssertLessThanOrEqual(
            ledger.droppedTraceTrackingCountForTesting,
            capacity * 2,
            "per-trace tracking must stay bounded by the retained window"
        )
    }

    /// The existing per-trace semantics survive the bound: a trace that still
    /// has retained events keeps reporting how many of its events were
    /// dropped.
    func testRetainedTraceKeepsItsDroppedCountUnderTheBound() {
        var ledger = TerminalEventLedger(capacity: 3)
        let first = TerminalEventTraceID("first")
        let second = TerminalEventTraceID("second")

        ledger.recordPtyRead(traceID: first, byteCount: 1)
        ledger.recordPtyRead(traceID: first, byteCount: 2)
        ledger.recordPtyRead(traceID: second, byteCount: 3)
        ledger.recordPtyRead(traceID: second, byteCount: 4)

        XCTAssertEqual(ledger.summary(for: first).droppedEventCount, 1)
        XCTAssertEqual(ledger.summary(for: second).droppedEventCount, 0)
    }

    // MARK: Git runner stderr draining

    /// A git subprocess that writes more than the pipe buffer (~64 KB) to an
    /// unread stderr pipe blocks forever, wedging the service's serial queue
    /// and queueing every later request (and its captured completion) behind
    /// it. The fake git below writes 200 KB to stderr; before the fix this
    /// test times out because `collectStatus` never returns.
    func testGitStatusRunnerSurvivesChattyStderr() throws {
        let binDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: binDirectoryURL) }

        let fakeGitURL = binDirectoryURL.appendingPathComponent("git")
        let script = """
        #!/bin/sh
        dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' 'e' 1>&2
        echo \(binDirectoryURL.path)
        exit 0
        """
        try script.write(to: fakeGitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGitURL.path
        )

        let originalPath = String(cString: getenv("PATH"))
        setenv("PATH", "\(binDirectoryURL.path):\(originalPath)", 1)
        defer { setenv("PATH", originalPath, 1) }

        let expectation = expectation(description: "collectStatus returns despite chatty stderr")
        DispatchQueue.global(qos: .utility).async {
            _ = TerminalGitStatusRunner.collectStatus(rootDirectoryPath: binDirectoryURL.path)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: Timeout.gitCollectSeconds)
    }
}
