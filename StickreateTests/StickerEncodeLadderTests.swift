import XCTest
@testable import Stickreate

/// Unit tests for the pure encode-ladder policy that drives the animated WebP
/// size search. No encoding, no images — just the candidate/quality ordering.
final class StickerEncodeLadderTests: XCTestCase {

    // MARK: - frameCandidateCounts

    /// A long clip starts at the capped 160 (never 220/240) and descends to the
    /// 8-frame floor.
    func testCandidatesDescendFromCappedStart() {
        let counts = StickerEncoder.frameCandidateCounts(sourceCount: 220)
        XCTAssertEqual(counts.first, 160)
        XCTAssertEqual(counts.last, 8)
        XCTAssertEqual(counts, counts.sorted(by: >), "candidates must be descending")
        XCTAssertEqual(Set(counts).count, counts.count, "candidates must be unique")
    }

    /// A short clip is tried at its full length, with the 8-frame floor below it.
    func testCandidatesKeepSourceCountForShortClips() {
        XCTAssertEqual(StickerEncoder.frameCandidateCounts(sourceCount: 5), [5])
        XCTAssertEqual(StickerEncoder.frameCandidateCounts(sourceCount: 10), [10, 8])
    }

    /// Fewer than two frames has no valid animation.
    func testCandidatesEmptyBelowTwo() {
        XCTAssertTrue(StickerEncoder.frameCandidateCounts(sourceCount: 1).isEmpty)
        XCTAssertTrue(StickerEncoder.frameCandidateCounts(sourceCount: 0).isEmpty)
    }

    // MARK: - EncodeLadder

    /// The moment the LOWEST quality fails, the candidate is abandoned (no higher
    /// qualities tried) and the next, smaller candidate is probed.
    func testLowestQualityFailureAbandonsCandidate() {
        var ladder = EncodeLadder(frameCounts: [160, 120, 30], qualities: [15, 25, 40])
        XCTAssertEqual(ladder.start(), .encode(frameCount: 160, quality: 15))
        XCTAssertEqual(ladder.advance(fit: false), .encode(frameCount: 120, quality: 15))
        XCTAssertEqual(ladder.advance(fit: false), .encode(frameCount: 30, quality: 15))
    }

    /// When the lowest quality fits, qualities ramp up and the highest that fits
    /// wins (a higher failure returns the previous fit).
    func testQualitiesRampUpAndHighestFittingWins() {
        var ladder = EncodeLadder(frameCounts: [30], qualities: [15, 25, 40])
        XCTAssertEqual(ladder.start(), .encode(frameCount: 30, quality: 15))
        XCTAssertEqual(ladder.advance(fit: true), .encode(frameCount: 30, quality: 25))
        XCTAssertEqual(ladder.advance(fit: true), .encode(frameCount: 30, quality: 40))
        XCTAssertEqual(ladder.advance(fit: false), .win(frameCount: 30, quality: 25))
    }

    /// If every quality fits, the top quality wins.
    func testAllQualitiesFitWinsTop() {
        var ladder = EncodeLadder(frameCounts: [30], qualities: [15, 25, 40])
        XCTAssertEqual(ladder.start(), .encode(frameCount: 30, quality: 15))
        XCTAssertEqual(ladder.advance(fit: true), .encode(frameCount: 30, quality: 25))
        XCTAssertEqual(ladder.advance(fit: true), .encode(frameCount: 30, quality: 40))
        XCTAssertEqual(ladder.advance(fit: true), .win(frameCount: 30, quality: 40))
    }

    /// Every candidate failing at its lowest quality exhausts the ladder.
    func testAllCandidatesFailExhausts() {
        var ladder = EncodeLadder(frameCounts: [160, 60], qualities: [15, 25])
        XCTAssertEqual(ladder.start(), .encode(frameCount: 160, quality: 15))
        XCTAssertEqual(ladder.advance(fit: false), .encode(frameCount: 60, quality: 15))
        XCTAssertEqual(ladder.advance(fit: false), .exhausted)
    }

    /// A single-quality ladder wins or abandons on that one probe.
    func testSingleQualityLadder() {
        var win = EncodeLadder(frameCounts: [30], qualities: [15])
        XCTAssertEqual(win.start(), .encode(frameCount: 30, quality: 15))
        XCTAssertEqual(win.advance(fit: true), .win(frameCount: 30, quality: 15))

        var drop = EncodeLadder(frameCounts: [30, 8], qualities: [15])
        XCTAssertEqual(drop.start(), .encode(frameCount: 30, quality: 15))
        XCTAssertEqual(drop.advance(fit: false), .encode(frameCount: 8, quality: 15))
    }

    /// Degenerate inputs never crash and report exhaustion.
    func testEmptyInputsExhaust() {
        var noCounts = EncodeLadder(frameCounts: [], qualities: [15])
        XCTAssertEqual(noCounts.start(), .exhausted)
        var noQualities = EncodeLadder(frameCounts: [30], qualities: [])
        XCTAssertEqual(noQualities.start(), .exhausted)
    }
}
