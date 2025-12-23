import Foundation
import CoreGraphics

public enum BoardOrientation {
    case standard   // a1 at bottom-left (dark); h1 light at bottom-right
    case rotated180
}

/// Estimates board orientation from a normalized square board image by sampling corner brightness.
public struct OrientationEstimator {
    public init() {}

    public func estimateOrientation(normalizedBoard: CGImage) -> (BoardOrientation, DetectionWarning?) {
        // Sample bottom-left (a1) and bottom-right (h1) squares; if the pattern is inverted, rotate.
        guard let stats = sampleCornerSquares(image: normalizedBoard) else {
            return (.standard, DetectionWarning(message: "Orientation check skipped (sampling failed)."))
        }
        // Expect bottom-right to be lighter than bottom-left on a standard board (dark a1).
        let expected = stats.bottomRightBrightness > stats.bottomLeftBrightness
        if expected {
            return (.standard, nil)
        } else {
            return (.rotated180, DetectionWarning(message: "Board rotated 180° based on corner brightness heuristic."))
        }
    }

    private func sampleCornerSquares(image: CGImage) -> CornerStats? {
        let squareSize = max(1, min(image.width, image.height) / 8)
        func meanBrightness(x: Int, y: Int) -> Double? {
            let rect = CGRect(x: x, y: y, width: squareSize, height: squareSize)
            return image.meanLuminance(in: rect)
        }
        // CGImage coordinates are origin at top-left; adjust ranks accordingly.
        guard
            let bl = meanBrightness(x: 0, y: image.height - squareSize),
            let br = meanBrightness(x: image.width - squareSize, y: image.height - squareSize)
        else { return nil }
        return CornerStats(bottomLeftBrightness: bl, bottomRightBrightness: br)
    }

    private struct CornerStats {
        let bottomLeftBrightness: Double
        let bottomRightBrightness: Double
    }
}

private extension CGImage {
    /// Compute mean luminance (simple average of RGB) in the given rectangle.
    func meanLuminance(in rect: CGRect) -> Double? {
        guard let cropped = self.cropping(to: rect) else { return nil }
        guard let data = cropped.dataProvider?.data else { return nil }
        guard let ptr = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = cropped.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }
        let width = cropped.width
        let height = cropped.height
        var total: Double = 0
        var count: Int = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * cropped.bytesPerRow) + (x * bytesPerPixel)
                let r = Double(ptr[offset])
                let g = Double(ptr[offset + 1])
                let b = Double(ptr[offset + 2])
                total += (r + g + b) / 3.0
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return total / Double(count * 255)
    }
}
