import UIKit
import Vision
import CoreImage

/// Automatic background removal using Apple's on-device Vision subject lifting.
enum BackgroundRemover {
    enum Failure: LocalizedError {
        case noSubject
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noSubject:
                "Couldn't find a subject to cut out."
            case .failed(let message):
                message
            }
        }
    }

    private static let context = CIContext()

    /// Returns the subject on a transparent background.
    /// Uses `VNGenerateForegroundInstanceMaskRequest` (iOS 17+).
    ///
    /// The Vision pass runs off the main thread so callers awaiting this method
    /// (typically the UI) stay responsive.
    static func removeBackground(from image: UIImage) async throws -> UIImage {
        let upright = image.upNormalized() ?? image
        guard let ciImage = CIImage(image: upright) else {
            throw Failure.failed("Couldn't read this image.")
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                do {
                    try handler.perform([request])
                    guard let result = request.results?.first else {
                        continuation.resume(throwing: Failure.noSubject)
                        return
                    }

                    let buffer = try result.generateMaskedImage(
                        ofInstances: result.allInstances,
                        from: handler,
                        croppedToInstancesExtent: false
                    )

                    let masked = CIImage(cvPixelBuffer: buffer)
                    guard let cgImage = context.createCGImage(masked, from: masked.extent) else {
                        continuation.resume(throwing: Failure.failed("Couldn't render the cut-out."))
                        return
                    }
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                } catch {
                    continuation.resume(throwing: Failure.failed(error.localizedDescription))
                }
            }
        }
    }
}
