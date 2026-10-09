import XCTest
import UIKit
@testable import Stickreate

/// Covers the "Original" semantics fix: `MaskEditor` keeps a pristine
/// `originalBase` and can restore it, while all existing geometry is unchanged.
@MainActor
final class MaskEditorTests: XCTestCase {

    private func image(width: Int, height: Int, color: UIColor = .red) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: - restoreOriginal()

    func testFreshEditorRestoreOriginalKeepsEverything() {
        let editor = MaskEditor(base: image(width: 8, height: 8), mask: nil, maxDimension: 64)
        XCTAssertFalse(editor.isLifted)

        editor.restoreOriginal()

        let snapshot = editor.maskSnapshot
        XCTAssertEqual(snapshot.width, 8)
        XCTAssertEqual(snapshot.height, 8)
        XCTAssertEqual(snapshot.bytes.count, 64)
        XCTAssertTrue(snapshot.bytes.allSatisfy { $0 == 255 })
    }

    func testRestoreOriginalReturnsToOriginalBaseAfterCutoutChange() {
        let original = image(width: 10, height: 6, color: .blue)
        let cutout = image(width: 4, height: 4, color: .green)

        // Simulates a subject lift: the working base is the cut-out, but the
        // pristine original is carried in.
        let editor = MaskEditor(base: cutout, mask: nil, maxDimension: 64, originalBase: original)
        XCTAssertEqual(editor.base.size, cutout.size)
        XCTAssertTrue(editor.isLifted)

        editor.restoreOriginal()

        XCTAssertFalse(editor.isLifted)
        XCTAssertEqual(editor.base.size, original.size)
        XCTAssertTrue(editor.base === editor.originalBase)

        let snapshot = editor.maskSnapshot
        XCTAssertEqual(snapshot.width, 10)
        XCTAssertEqual(snapshot.height, 6)
        XCTAssertTrue(snapshot.bytes.allSatisfy { $0 == 255 })
    }

    func testUndoRestoresLiftedStateAfterRestoreOriginal() {
        let original = image(width: 12, height: 12, color: .blue)
        let cutout = image(width: 6, height: 6, color: .green)
        let editor = MaskEditor(base: cutout, mask: nil, maxDimension: 64, originalBase: original)

        editor.restoreOriginal()
        XCTAssertFalse(editor.isLifted)

        editor.undo()

        XCTAssertTrue(editor.isLifted)
        XCTAssertEqual(editor.base.size, cutout.size)
    }

    func testRestoreOriginalUndoesBakedCrop() {
        let editor = MaskEditor(base: image(width: 20, height: 20), mask: nil, maxDimension: 64)
        editor.applyCrop(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(editor.maskSnapshot.width, 10)
        XCTAssertEqual(editor.maskSnapshot.height, 10)

        editor.restoreOriginal()

        XCTAssertEqual(editor.maskSnapshot.width, 20)
        XCTAssertEqual(editor.maskSnapshot.height, 20)
        XCTAssertTrue(editor.maskSnapshot.bytes.allSatisfy { $0 == 255 })
    }

    // MARK: - Existing geometry

    func testSelectRectangleUsesTopLeftOrigin() {
        let editor = MaskEditor(base: image(width: 8, height: 8), mask: nil, maxDimension: 64)

        editor.selectRectangle(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), removing: true)

        let snapshot = editor.maskSnapshot
        for y in 0..<8 {
            for x in 0..<8 {
                let value = snapshot.bytes[y * snapshot.width + x]
                if x < 4, y < 4 {
                    XCTAssertEqual(value, 0, "expected removed at (\(x), \(y))")
                } else {
                    XCTAssertEqual(value, 255, "expected kept at (\(x), \(y))")
                }
            }
        }
    }

    func testUndoRestoresMaskAfterSelection() {
        let editor = MaskEditor(base: image(width: 8, height: 8), mask: nil, maxDimension: 64)
        editor.selectRectangle(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), removing: true)
        XCTAssertEqual(editor.maskSnapshot.bytes[0], 0)

        editor.undo()

        XCTAssertTrue(editor.maskSnapshot.bytes.allSatisfy { $0 == 255 })
    }
}
