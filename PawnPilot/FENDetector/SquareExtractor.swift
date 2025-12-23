import Foundation
import CoreGraphics

public struct SquareCrop {
    public let image: CGImage
    public let position: (file: Int, rank: Int)
}

public enum SquareExtractionError: Error {
    case invalidBoardImage
}

/// Splits a normalized board into 64 square crops.
public final class SquareExtractor {
    private let padFraction: CGFloat
    private let refinedPadFraction: CGFloat
    private let useGridRefinement: Bool
    private let loggingEnabled: Bool

    /// - parameter padFraction: padding added to each square crop relative to square size (e.g., 0.12 adds 12% on each side).
    /// - parameter useGridRefinement: if true, try to detect grid lines via contrast to refine square boundaries.
    /// - parameter refinedPadFraction: padding when grid refinement succeeds (kept smaller to stay tight on cells).
    public init(padFraction: CGFloat = 0.12, refinedPadFraction: CGFloat = 0.02, useGridRefinement: Bool = true, loggingEnabled: Bool = false) {
        self.padFraction = padFraction
        self.refinedPadFraction = refinedPadFraction
        self.useGridRefinement = useGridRefinement
        self.loggingEnabled = loggingEnabled
    }

    /// Backwards-compatible initializer without logging flag.
    public convenience init(padFraction: CGFloat = 0.12, refinedPadFraction: CGFloat = 0.02, useGridRefinement: Bool = true) {
        self.init(padFraction: padFraction, refinedPadFraction: refinedPadFraction, useGridRefinement: useGridRefinement, loggingEnabled: false)
    }

    public func extractSquares(from normalized: NormalizedBoard) throws -> [SquareCrop] {
        let width = normalized.image.width
        let height = normalized.image.height
        guard width == height else { throw SquareExtractionError.invalidBoardImage }

        let squareSize = width / 8
        var crops: [SquareCrop] = []
        crops.reserveCapacity(64)

        let uniformGrid = (xLines: (0...8).map { Int(CGFloat($0) * CGFloat(squareSize)) },
                           yLines: (0...8).map { Int(CGFloat($0) * CGFloat(squareSize)) })

        let chosenGrid: (xLines: [Int], yLines: [Int])
        let usingRefinedGrid: Bool

        if useGridRefinement {
            let refinedGrid = GridRefiner().refineGrid(in: normalized.image)
            let contrastEvaluator = GridContrastEvaluator(image: normalized.image)
            let uniformScore = contrastEvaluator.scoreGrid(xLines: uniformGrid.xLines, yLines: uniformGrid.yLines)
            var refinedScore: Double?
            var selected = uniformGrid
            var selectedIsRefined = false
            if let refined = refinedGrid {
                refinedScore = contrastEvaluator.scoreGrid(xLines: refined.xLines, yLines: refined.yLines)
                if let rScore = refinedScore, let uScore = uniformScore {
                    if rScore >= uScore {
                        selected = refined
                        selectedIsRefined = true
                    }
                } else if refinedScore != nil, uniformScore == nil {
                    selected = refined
                    selectedIsRefined = true
                }
            }

            if loggingEnabled {
                if selectedIsRefined {
                    print("GridRefiner: refined grid accepted; contrastScore=\(refinedScore ?? -1) uniformScore=\(uniformScore ?? -1) xLines=\(selected.xLines) yLines=\(selected.yLines)")
                } else if refinedGrid != nil {
                    print("GridRefiner: refined grid rejected; contrastScore=\(refinedScore ?? -1) uniformScore=\(uniformScore ?? -1)")
                } else {
                    print("GridRefiner: refinement failed, using uniform grid (uniformScore=\(uniformScore ?? -1))")
                }
            }
            chosenGrid = selected
            usingRefinedGrid = selectedIsRefined
        } else {
            chosenGrid = uniformGrid
            usingRefinedGrid = false
        }

        let xLines = chosenGrid.xLines
        let yLines = chosenGrid.yLines
        let padPixels = Int(CGFloat(squareSize) * (usingRefinedGrid ? refinedPadFraction : padFraction))
        if loggingEnabled {
            print("SquareExtractor: using padFraction=\(usingRefinedGrid ? refinedPadFraction : padFraction) (~\(padPixels) px) gridUsed=\(usingRefinedGrid)")
        }

        for rank in 0..<8 {
            for file in 0..<8 {
                let originX = xLines[file]
                let originY = yLines[rank]
                let nextX = xLines[file + 1]
                let nextY = yLines[rank + 1]
                let boardRank = 7 - rank // convert image-top origin to board-bottom origin
                let rect = CGRect(
                    x: max(0, originX - padPixels),
                    y: max(0, originY - padPixels),
                    width: min((nextX - originX) + padPixels * 2, width - max(0, originX - padPixels)),
                    height: min((nextY - originY) + padPixels * 2, height - max(0, originY - padPixels))
                )
                if let crop = normalized.image.cropping(to: rect) {
                    crops.append(SquareCrop(image: crop, position: (file, boardRank)))
                }
            }
        }
        return crops
    }
}

/// Evaluates how well grid lines align to the board's color/contrast pattern by sampling all 64 cells.
private struct GridContrastEvaluator {
    let image: CGImage

    func scoreGrid(xLines: [Int], yLines: [Int]) -> Double? {
        guard xLines.count == 9, yLines.count == 9 else { return nil }
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }

        var luminanceGrid = Array(repeating: Array(repeating: 0.0, count: 8), count: 8)
        for rank in 0..<8 {
            for file in 0..<8 {
                let x0 = xLines[file]
                let x1 = xLines[file + 1]
                let y0 = yLines[rank]
                let y1 = yLines[rank + 1]
                guard let luma = meanLuminance(
                    ptr: ptr,
                    bpp: bpp,
                    bpr: image.bytesPerRow,
                    width: image.width,
                    height: image.height,
                    x0: x0,
                    x1: x1,
                    y0: y0,
                    y1: y1
                ) else {
                    return nil
                }
                luminanceGrid[rank][file] = luma
            }
        }

        var neighborDiffs: [Double] = []
        for rank in 0..<8 {
            for file in 0..<8 {
                if file < 7 {
                    neighborDiffs.append(abs(luminanceGrid[rank][file] - luminanceGrid[rank][file + 1]))
                }
                if rank < 7 {
                    neighborDiffs.append(abs(luminanceGrid[rank][file] - luminanceGrid[rank + 1][file]))
                }
            }
        }
        guard !neighborDiffs.isEmpty else { return nil }
        let neighborScore = neighborDiffs.reduce(0, +) / Double(neighborDiffs.count)

        var lightSquares: [Double] = []
        var darkSquares: [Double] = []
        for rank in 0..<8 {
            for file in 0..<8 {
                if (rank + file) % 2 == 0 {
                    lightSquares.append(luminanceGrid[rank][file])
                } else {
                    darkSquares.append(luminanceGrid[rank][file])
                }
            }
        }
        let lightMean = lightSquares.average
        let darkMean = darkSquares.average
        let patternScore = lightMean != nil && darkMean != nil ? abs((lightMean ?? 0) - (darkMean ?? 0)) : 0

        return neighborScore + patternScore
    }

    private func meanLuminance(
        ptr: UnsafePointer<UInt8>,
        bpp: Int,
        bpr: Int,
        width: Int,
        height: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int
    ) -> Double? {
        guard x1 > x0, y1 > y0 else { return nil }
        let insetX = max(1, (x1 - x0) / 10)
        let insetY = max(1, (y1 - y0) / 10)
        let startX = min(max(0, x0 + insetX), width)
        let endX = min(width, max(startX + 1, x1 - insetX))
        let startY = min(max(0, y0 + insetY), height)
        let endY = min(height, max(startY + 1, y1 - insetY))
        if endX <= startX || endY <= startY { return nil }

        var total: Double = 0
        var count = 0
        for y in startY..<endY {
            let row = y * bpr
            for x in startX..<endX {
                let offset = row + x * bpp
                total += Double(ptr[offset]) + Double(ptr[offset + 1]) + Double(ptr[offset + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return total / (Double(count) * 3.0 * 255.0)
    }
}

private extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}
