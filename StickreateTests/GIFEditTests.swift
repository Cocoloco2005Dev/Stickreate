import XCTest
@testable import Stickreate

/// Pure tests for the GIF trim rule: which decoded frames survive a chosen
/// range, based on their real delays. No GIF decoding, no UI — the rule lives in
/// `StickerFactory.frameRange(for:durations:)` and is exercised directly.
final class GIFEditTests: XCTestCase {

    /// Ten 100 ms frames: 0.0 ... 1.0 s, each covering [k*0.1, (k+1)*0.1).
    private let tenths = Array(repeating: 0.1, count: 10)

    /// A range covering everything keeps every frame.
    func testFullRangeKeepsAllFrames() {
        XCTAssertEqual(StickerFactory.frameRange(for: 0...1.0, durations: tenths), 0..<10)
    }

    /// Frames whose intervals overlap the range survive; partial-overlap frames
    /// at both edges are kept so the trimmed span is never short.
    func testRangeKeepsOverlappingFrames() {
        // [0.25, 0.55): frame 1 ends at 0.2 (no), frame 2 covers 0.2–0.3 (yes)
        // through frame 5 covering 0.5–0.6 (yes); frame 6 starts at 0.6 (no).
        XCTAssertEqual(StickerFactory.frameRange(for: 0.25...0.55, durations: tenths), 2..<6)
    }

    /// A range snapped to frame boundaries selects exactly those frames.
    func testRangeOnExactBoundaries() {
        XCTAssertEqual(StickerFactory.frameRange(for: 0.2...0.4, durations: tenths), 2..<4)
    }

    /// A range at the very start keeps only the first frame.
    func testRangeAtStartKeepsFirstFrame() {
        XCTAssertEqual(StickerFactory.frameRange(for: 0...0.05, durations: tenths), 0..<1)
    }

    /// A range past the end selects nothing.
    func testRangePastEndIsEmpty() {
        XCTAssertEqual(StickerFactory.frameRange(for: 5...6, durations: tenths), 0..<0)
    }

    /// Varying delays are respected: the selected frames' summed time must cover
    /// the requested span (the encoder then redistributes to make it exact).
    func testSelectedFramesCoverRequestedSpan() {
        let durations: [TimeInterval] = [0.04, 0.08, 0.02, 0.1, 0.16, 0.02, 0.3]
        let range: ClosedRange<TimeInterval> = 0.05...0.30
        let selection = StickerFactory.frameRange(for: range, durations: durations)
        XCTAssertFalse(selection.isEmpty)
        let covered = durations[selection].reduce(0, +)
        XCTAssertGreaterThanOrEqual(covered, range.upperBound - range.lowerBound - 1e-9)
    }

    /// The selected range is always a valid, in-bounds, contiguous slice.
    func testSelectionStaysInBounds() {
        let selection = StickerFactory.frameRange(for: -1...0.35, durations: tenths)
        XCTAssertGreaterThanOrEqual(selection.lowerBound, 0)
        XCTAssertLessThanOrEqual(selection.upperBound, tenths.count)
        XCTAssertLessThanOrEqual(selection.lowerBound, selection.upperBound)
    }

    /// Empty input never crashes and yields an empty range.
    func testEmptyDurations() {
        XCTAssertEqual(StickerFactory.frameRange(for: 0...1, durations: []), 0..<0)
    }
}
