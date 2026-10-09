import XCTest
@testable import Stickreate

/// Unit tests for the pure GIF downsampling rule. Building a real 100-frame GIF
/// is heavy, so the delay-summing is factored into `downsampledDelays` and tested
/// directly (the thing that was dropping duration, P1-1).
final class FrameExtractorGIFTests: XCTestCase {

    /// Keeping 1-in-`step` frames must preserve total duration: each kept frame
    /// carries the summed delays of the frames it replaces.
    func testDownsampledGIFPreservesTotalDuration() {
        let frameDelay = 1.0 / 30.0
        let base = Array(repeating: frameDelay, count: 100)
        let kept = FrameExtractor.downsampledDelays(baseDelays: base, step: 4)
        XCTAssertEqual(kept.count, 25)
        XCTAssertEqual(kept[0], frameDelay * 4, accuracy: 1e-12)
        XCTAssertEqual(kept.reduce(0, +), base.reduce(0, +), accuracy: 1e-9)
    }

    /// The final group is short when the frame count isn't a multiple of `step`.
    func testDownsampledGIFSumsTrailingPartialGroup() {
        let base = (0..<10).map { Double($0 + 1) / 100.0 } // 0.01 ... 0.10
        let kept = FrameExtractor.downsampledDelays(baseDelays: base, step: 3)
        XCTAssertEqual(kept.count, 4) // [0,1,2] [3,4,5] [6,7,8] [9]
        XCTAssertEqual(kept[3], base[9], accuracy: 1e-12)
        XCTAssertEqual(kept.reduce(0, +), base.reduce(0, +), accuracy: 1e-12)
    }

    /// `step == 1` skips nothing, so the delays are returned unchanged.
    func testDownsampledGIFStepOneIsIdentity() {
        let base = [0.1, 0.2, 0.3]
        XCTAssertEqual(FrameExtractor.downsampledDelays(baseDelays: base, step: 1), base)
    }

    /// Empty input yields empty output (no crash, no phantom frame).
    func testDownsampledGIFEmpty() {
        XCTAssertTrue(FrameExtractor.downsampledDelays(baseDelays: [], step: 4).isEmpty)
    }
}
