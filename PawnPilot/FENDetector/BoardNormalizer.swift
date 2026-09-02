import Foundation
import CoreImage
import CoreGraphics

nonisolated public struct NormalizedBoard: Sendable {
    public let image: CGImage
    public let size: CGSize
}

public enum BoardNormalizationError: Error {
    case unableToCreateImage
}

nonisolated public final class BoardNormalizer: Sendable {
    private let context: CIContext

    public init(context: CIContext = CIContext()) {
        self.context = context
    }

    /// The pipeline is this method's only caller and it runs it off the main actor (E9 of
    /// `(detection-off-main-actor)`).
    private static func assertOffMain() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
    }

    /// Rectify the detected board quadrilateral into a square CGImage of `targetSize`.
    public func normalize(
        image cgImage: CGImage,
        quad: BoardQuadrilateral,
        targetSize: CGSize = CGSize(width: 1024, height: 1024)
    ) throws -> NormalizedBoard {
        Self.assertOffMain()
        let ciImage = CIImage(cgImage: cgImage)

        // First, correct perspective into a rectangular patch.
        guard let correction = CIFilter(name: "CIPerspectiveCorrection") else {
            throw BoardNormalizationError.unableToCreateImage
        }
        correction.setValue(ciImage, forKey: kCIInputImageKey)
        correction.setValue(CIVector(cgPoint: quad.topLeft), forKey: "inputTopLeft")
        correction.setValue(CIVector(cgPoint: quad.topRight), forKey: "inputTopRight")
        correction.setValue(CIVector(cgPoint: quad.bottomRight), forKey: "inputBottomRight")
        correction.setValue(CIVector(cgPoint: quad.bottomLeft), forKey: "inputBottomLeft")

        guard let corrected = correction.outputImage else {
            throw BoardNormalizationError.unableToCreateImage
        }

        // Then scale to the desired canonical square size.
        let scaleX = targetSize.width / corrected.extent.width
        let scaleY = targetSize.height / corrected.extent.height
        let scaled = corrected.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(origin: .zero, size: targetSize))

        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            throw BoardNormalizationError.unableToCreateImage
        }
        return NormalizedBoard(image: cg, size: targetSize)
    }
}
