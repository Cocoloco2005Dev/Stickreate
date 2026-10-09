import XCTest
@testable import Stickreate

/// Unit tests for the pure creation-progress accumulator: it must be monotonic,
/// clamp injected values into `0...1`, and compose stage-local fractions into one
/// overall fraction via its weights.
final class StickerProgressTests: XCTestCase {

    func testUpdateIsMonotonicAndNeverDecreases() {
        var accumulator = ProgressAccumulator()
        XCTAssertEqual(accumulator.update(0.4), 0.4, accuracy: 1e-9)
        XCTAssertEqual(accumulator.update(0.2), 0.4, accuracy: 1e-9)
        XCTAssertEqual(accumulator.update(0.6), 0.6, accuracy: 1e-9)
        XCTAssertEqual(accumulator.update(0.5), 0.6, accuracy: 1e-9)
    }

    /// Within range `update` is the identity (injective); out of range it clamps.
    func testUpdateClampsIntoUnitRange() {
        var high = ProgressAccumulator()
        XCTAssertEqual(high.update(1.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(high.update(2.0), 1.0, accuracy: 1e-9)

        var low = ProgressAccumulator()
        XCTAssertEqual(low.update(-1.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(low.update(0.0), 0.0, accuracy: 1e-9)

        var identity = ProgressAccumulator()
        XCTAssertEqual(identity.update(0.125), 0.125, accuracy: 1e-9)
        XCTAssertEqual(identity.update(0.875), 0.875, accuracy: 1e-9)
    }

    /// Stage weights partition the bar, so a completed stage lands at its
    /// lower bound + weight and a full run reaches exactly 1.
    func testStagesComposeIntoSingleFraction() {
        var accumulator = ProgressAccumulator()
        XCTAssertEqual(
            accumulator.update(1.0, in: .cut),
            ProgressAccumulator.Stage.cut.lowerBound + ProgressAccumulator.Stage.cut.weight,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            accumulator.update(1.0, in: .saving),
            1.0,
            accuracy: 1e-9
        )
        let total = ProgressAccumulator.Stage.allCases.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(total, 1.0, accuracy: 1e-9)
    }

    /// A stage-local fraction maps into its own slice, never before it.
    func testStageFractionStaysWithinItsSlice() {
        var accumulator = ProgressAccumulator()
        let start = ProgressAccumulator.Stage.compression.lowerBound
        let value = accumulator.update(0.5, in: .compression)
        XCTAssertGreaterThanOrEqual(value, start)
        XCTAssertLessThanOrEqual(
            value,
            start + ProgressAccumulator.Stage.compression.weight,
            "a 0...1 stage fraction must stay inside the stage's slice"
        )
    }

    /// Pins the exact overall ranges the UI bar now depends on: each stage starts
    /// where the previous ended, so the single bar is continuous across boundaries
    /// (extracting 0→0.30, cutting 0.30→0.65, compressing 0.65→0.95, saving →1.0).
    func testStageSlicesAreContiguousAcrossTheBar() {
        let extraction = ProgressAccumulator.Stage.extraction
        let cut = ProgressAccumulator.Stage.cut
        let compression = ProgressAccumulator.Stage.compression
        let saving = ProgressAccumulator.Stage.saving

        XCTAssertEqual(extraction.lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(extraction.lowerBound + extraction.weight, cut.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(cut.lowerBound + cut.weight, compression.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(compression.lowerBound + compression.weight, saving.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(saving.lowerBound + saving.weight, 1.0, accuracy: 1e-9)

        // A completed stage lands exactly on the next stage's start (no reset).
        var accumulator = ProgressAccumulator()
        XCTAssertEqual(accumulator.update(1.0, in: .extraction), cut.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(accumulator.update(1.0, in: .compression), saving.lowerBound, accuracy: 1e-9)
    }
}
