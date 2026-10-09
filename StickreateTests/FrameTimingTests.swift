import XCTest
import UIKit
@testable import Stickreate

/// Frame-duration distribution rules for animation encoding, exercised through
/// the `StickerEncoder.preparedFramesForTesting` seam:
///
/// - durations never fall below the 8 ms WhatsApp floor,
/// - animations are proportionally rescaled to the 10 s ceiling,
/// - when the rescale pushes a frame below the floor it is dropped,
/// - otherwise the durations sum exactly to the requested span.
///
/// `StickerEncoder.targetMilliseconds(_:targetDuration:)` (the whole-millisecond
/// redistribution to an exact span) is `private` with no test seam, so its exact
/// sum is only assert-guarded inside the encoder (Debug). The integration test at
/// the bottom drives that path end to end to trip that assertion.
final class FrameTimingTests: XCTestCase {

    private let accuracy: TimeInterval = 1e-9

    /// An already-512×512 upright image, so `prepare` passes it through instead of
    /// redrawing — keeps the property tests fast and allocation-free.
    private func canvasImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let bounds = CGRect(x: 0, y: 0, width: 512, height: 512)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(bounds)
        }
    }

    func testPreparedDurationsSumToSpanForManyCountsAndSpans() {
        let image = canvasImage()
        let pairs: [(count: Int, span: TimeInterval)] = [
            (2, 0.02),
            (3, 0.1),
            (5, 1),
            (8, 5),
            (24, 9.9),
            (50, 9.9),
            (100, 9.9)
        ]

        for (count, span) in pairs {
            let perFrame = span / TimeInterval(count)
            // Pairs are chosen so no frame needs the 8 ms floor and nothing is
            // rescaled; `prepare` must then preserve the total exactly.
            XCTAssertGreaterThanOrEqual(perFrame, Limits.minFrameDuration)
            let frames = (0..<count).map { _ in Frame(image: image, duration: perFrame) }

            let prepared = StickerEncoder.preparedFramesForTesting(frames)
            XCTAssertEqual(prepared.count, count, "count=\(count) span=\(span) must not drop frames")
            let sum = prepared.reduce(0) { $0 + $1.duration }
            XCTAssertEqual(sum, span, accuracy: accuracy, "count=\(count) span=\(span)")
        }
    }

    func testPreparedEnforcesMinimumFrameDuration() {
        let image = canvasImage()
        let frames = [0.001, 0.002, 0.004].map { Frame(image: image, duration: $0) }

        let prepared = StickerEncoder.preparedFramesForTesting(frames)

        XCTAssertEqual(prepared.count, 3)
        XCTAssertTrue(
            prepared.allSatisfy { $0.duration >= Limits.minFrameDuration },
            "every frame must be raised to the 8 ms floor: \(prepared.map(\.duration))"
        )
        let sum = prepared.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(sum, 3 * Limits.minFrameDuration, accuracy: accuracy)
    }

    func testPreparedRescalesAnimationsLongerThanTenSeconds() {
        let image = canvasImage()
        let frames = (0..<100).map { _ in Frame(image: image, duration: 0.5) } // 50 s

        let prepared = StickerEncoder.preparedFramesForTesting(frames)

        XCTAssertEqual(prepared.count, 100, "0.1 s frames stay above the floor after rescale")
        let sum = prepared.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(sum, Limits.maxAnimationDuration, accuracy: accuracy)
        XCTAssertTrue(prepared.allSatisfy { $0.duration >= Limits.minFrameDuration })
    }

    func testPreparedDropsFramesPushedBelowFloorByRescale() {
        let image = canvasImage()
        // 20 s total: rescale to 10 s halves the long frame (→ ~10 s, kept) and
        // pushes the two tiny frames far below 8 ms, so they are dropped.
        let frames = [
            Frame(image: image, duration: 20),
            Frame(image: image, duration: 0.0005),
            Frame(image: image, duration: 0.0005)
        ]

        let prepared = StickerEncoder.preparedFramesForTesting(frames)

        XCTAssertEqual(prepared.count, 1, "sub-floor frames after rescale must be dropped")
        guard let kept = prepared.first else {
            XCTFail("the long frame should survive the rescale")
            return
        }
        XCTAssertGreaterThanOrEqual(kept.duration, Limits.minFrameDuration)
        let sum = prepared.reduce(0) { $0 + $1.duration }
        XCTAssertLessThanOrEqual(sum, Limits.maxAnimationDuration)
    }

    func testPreparedEmptyInputReturnsEmpty() {
        XCTAssertTrue(StickerEncoder.preparedFramesForTesting([]).isEmpty)
    }

    /// Drives `animatedSticker(targetDuration:)` across several (count, span)
    /// pairs. In a Debug build this exercises the encoder's internal
    /// `assert(durations.sum == targetMs)`; from outside the module we can only
    /// observe that a compliant payload of the right budget comes back.
    func testAnimatedStickerHonorsTargetDurationAcrossCountsAndSpans() {
        let image = canvasImage()
        let pairs: [(count: Int, span: TimeInterval)] = [(2, 0.016), (3, 1), (5, 9.9)]

        for (count, span) in pairs {
            let frames = (0..<count).map { _ in Frame(image: image, duration: span / TimeInterval(count)) }
            let data = StickerEncoder.animatedSticker(from: frames, targetDuration: span)
            guard let data else {
                XCTFail("count=\(count) span=\(span) should encode a payload")
                continue
            }
            XCTAssertLessThanOrEqual(data.count, Limits.maxAnimatedBytes)
            XCTAssertLessThanOrEqual(data.count, 480 * 1024)
        }
    }
}
