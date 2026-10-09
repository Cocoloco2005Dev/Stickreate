import XCTest
@testable import Stickreate

/// Unit tests for the pure frame→mask assignment that drives the motion-following
/// Intelligent Cut. Vision itself is not exercised here (device-only); this pins
/// the subsample + nearest-mask-reuse + failure-reuse-previous rules.
final class StickerCutTests: XCTestCase {

    /// With every anchor succeeding, each frame uses its bucket's anchor.
    func testEveryFrameMapsToItsBucketAnchor() {
        let expected: [Int?] = [0, 0, 0, 3, 3, 3, 6, 6, 6, 9]
        XCTAssertEqual(
            StickerFactory.maskAssignments(frameCount: 10, stride: 3, successfulAnchors: [0, 3, 6, 9]),
            expected
        )
    }

    /// A failed anchor's frames reuse the previous successful mask.
    func testFailedAnchorReusesPreviousMask() {
        // Anchor 3 failed; frames 3...5 must fall back to anchor 0.
        let expected: [Int?] = [0, 0, 0, 0, 0, 0, 6, 6, 6, 9, 9, 9]
        XCTAssertEqual(
            StickerFactory.maskAssignments(frameCount: 12, stride: 3, successfulAnchors: [0, 6, 9]),
            expected
        )
    }

    /// Frames before the first successful anchor have no mask to reuse and are
    /// left uncut (nil).
    func testLeadingFramesBeforeFirstSuccessAreUncut() {
        let expected: [Int?] = [nil, nil, nil, nil, nil, nil, 6, 6, 6]
        XCTAssertEqual(
            StickerFactory.maskAssignments(frameCount: 9, stride: 3, successfulAnchors: [6]),
            expected
        )
    }

    /// A single successful anchor is held across the whole clip.
    func testSingleAnchorCoversWholeClip() {
        let expected: [Int?] = [0, 0, 0, 0, 0]
        XCTAssertEqual(
            StickerFactory.maskAssignments(frameCount: 5, stride: 3, successfulAnchors: [0]),
            expected
        )
    }

    /// No successful pass leaves every frame uncut.
    func testNoSuccessfulAnchorsLeavesAllUncut() {
        let expected: [Int?] = [nil, nil, nil, nil]
        XCTAssertEqual(
            StickerFactory.maskAssignments(frameCount: 4, stride: 3, successfulAnchors: []),
            expected
        )
    }

    /// A non-positive stride is degenerate and must not crash or map anything.
    func testNonPositiveStrideReturnsAllNil() {
        let expected: [Int?] = [nil, nil, nil, nil]
        XCTAssertEqual(
            StickerFactory.maskAssignments(frameCount: 4, stride: 0, successfulAnchors: [0]),
            expected
        )
    }

    /// Zero frames yields an empty assignment.
    func testZeroFramesReturnsEmpty() {
        XCTAssertTrue(
            StickerFactory.maskAssignments(frameCount: 0, stride: 3, successfulAnchors: []).isEmpty
        )
    }

    /// A realistic 24-frame clip at the production stride: every frame is mapped
    /// and only anchors 0, 3, …, 21 are ever referenced.
    func testProductionStrideCoversEveryFrame() {
        let anchors = Array(Swift.stride(from: 0, to: 24, by: 3))
        let assignment = StickerFactory.maskAssignments(
            frameCount: 24,
            stride: 3,
            successfulAnchors: anchors
        )
        XCTAssertEqual(assignment.count, 24)
        XCTAssertTrue(assignment.allSatisfy { $0 != nil })
        XCTAssertTrue(assignment.allSatisfy { anchors.contains($0!) })
    }
}
