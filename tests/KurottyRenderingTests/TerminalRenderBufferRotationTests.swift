@testable import KurottyApp
import XCTest

@MainActor
final class TerminalRenderBufferRotationTests: XCTestCase {
    func testFirstAcquisitionUploadsIntoTheFirstSlot() {
        var rotation = TerminalRenderBufferRotation(slotCount: 3)

        let acquisition = rotation.acquireSlot(forPayloadRevision: 1)

        XCTAssertEqual(acquisition.slot, 0)
        XCTAssertTrue(acquisition.requiresUpload)
        XCTAssertEqual(rotation.currentSlot, 0)
        XCTAssertEqual(rotation.residentRevision(inSlot: 0), 1)
    }

    func testUnchangedPayloadReEncodesFromTheSameSlotWithoutCopying() {
        var rotation = TerminalRenderBufferRotation(slotCount: 3)
        let first = rotation.acquireSlot(forPayloadRevision: 7)

        let second = rotation.acquireSlot(forPayloadRevision: 7)

        XCTAssertEqual(second.slot, first.slot)
        XCTAssertFalse(second.requiresUpload, "a frame that re-encodes unchanged bytes must not rewrite a buffer the GPU may still read")
    }

    func testEachNewPayloadRotatesOntoTheNextSlotAndWrapsAround() {
        var rotation = TerminalRenderBufferRotation(slotCount: 3)

        let slots = (1...4).map { revision in
            rotation.acquireSlot(forPayloadRevision: UInt64(revision)).slot
        }

        XCTAssertEqual(slots, [0, 1, 2, 0])
    }

    func testSlotCountIsClampedToAtLeastOne() {
        var rotation = TerminalRenderBufferRotation(slotCount: 0)

        XCTAssertEqual(rotation.slotCount, 1)
        XCTAssertEqual(rotation.acquireSlot(forPayloadRevision: 1).slot, 0)
        XCTAssertEqual(rotation.acquireSlot(forPayloadRevision: 2).slot, 0)
    }

    /// The safety property the triple buffering exists for: a frame may only write a slot
    /// whose previous user has already retired. With `maxBuffersInFlight` semaphore
    /// permits, frame `f` runs only once frame `f - maxBuffersInFlight` has completed, so
    /// every rewritten slot must have last been touched at least that many frames ago.
    func testSlotIsNeverRewrittenWhileAnOutstandingFrameCouldStillReadIt() {
        let slotCount = TerminalMetalView.maxBuffersInFlight
        var rotation = TerminalRenderBufferRotation(slotCount: slotCount)
        var revision: UInt64 = 0
        var lastFrameTouchingSlot: [Int: Int] = [:]

        for frameIndex in 0..<500 {
            // Model a renderer whose model updates land on an irregular subset of frames.
            if frameIndex % 5 != 1 && frameIndex % 7 != 3 {
                revision &+= 1
            }
            let acquisition = rotation.acquireSlot(forPayloadRevision: revision)
            if acquisition.requiresUpload, let previousFrame = lastFrameTouchingSlot[acquisition.slot] {
                XCTAssertLessThanOrEqual(
                    previousFrame,
                    frameIndex - slotCount,
                    "frame \(frameIndex) would overwrite slot \(acquisition.slot) last used by frame \(previousFrame), which may still be in flight"
                )
            }
            lastFrameTouchingSlot[acquisition.slot] = frameIndex
        }

        XCTAssertEqual(lastFrameTouchingSlot.count, slotCount, "every slot must take part in the rotation")
    }

    func testRendererKeepsThreeFramesInFlight() {
        XCTAssertEqual(TerminalMetalView.maxBuffersInFlight, 3)
    }
}
