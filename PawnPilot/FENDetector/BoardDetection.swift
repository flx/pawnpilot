import Foundation
import CoreGraphics

public struct BoardQuadrilateral: Codable, Hashable, @unchecked Sendable {
    /// Points in image pixel coordinates (origin at bottom-left for CGImage/Vision conversion).
    public let topLeft: CGPoint
    public let topRight: CGPoint
    public let bottomRight: CGPoint
    public let bottomLeft: CGPoint

    public var boundingBox: CGRect {
        let xs = [topLeft.x, topRight.x, bottomRight.x, bottomLeft.x]
        let ys = [topLeft.y, topRight.y, bottomRight.y, bottomLeft.y]
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public struct BoardDetectionResult {
    public let quad: BoardQuadrilateral
    public let confidence: Float
}

public enum BoardDetectionError: Error {
    case noBoardFound
}

/// Wraps Vision rectangle detection to find the best chessboard candidate.
public final class BoardDetector {
    public init() {}

    public func detectBoard(in cgImage: CGImage) async throws -> BoardDetectionResult {
        if let quad = Self.edgeBasedDetect(image: cgImage) {
            return BoardDetectionResult(quad: quad, confidence: 0.2)
        }
        if let fallback = Self.centeredSquareFallback(image: cgImage) {
            return BoardDetectionResult(quad: fallback, confidence: 0.05)
        }
        throw BoardDetectionError.noBoardFound
    }

    /// Edge-based detection: find a checkered band by scanning rows/cols for long alternating runs.
    private static func edgeBasedDetect(image: CGImage) -> BoardQuadrilateral? {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        let bpr = image.bytesPerRow
        let width = image.width
        let height = image.height
        func luminance(_ x: Int, _ y: Int) -> Double {
            let o = y * bpr + x * bpp
            return (Double(ptr[o]) + Double(ptr[o + 1]) + Double(ptr[o + 2])) / (3.0 * 255.0)
        }

        // Scan rows for horizontal checkered pattern.
        var startXs: [Int] = []
        var endXs: [Int] = []
        for y in 0..<height {
            if let band = bestCheckeredBand(inRow: y, width: width, luminance: luminance) {
                startXs.append(band.start)
                endXs.append(band.end)
            }
        }

        // Scan columns for vertical checkered pattern.
        var startYs: [Int] = []
        var endYs: [Int] = []
        for x in 0..<width {
            if let band = bestCheckeredBand(inColumn: x, height: height, luminance: luminance) {
                startYs.append(band.start)
                endYs.append(band.end)
            }
        }

        guard
            let x0 = modeValue(startXs, binWidth: 6),
            let x1 = modeValue(endXs, binWidth: 6),
            let y0 = modeValue(startYs, binWidth: 6),
            let y1 = modeValue(endYs, binWidth: 6)
        else {
            return nil
        }

        // Convert from top-left pixel origin to bottom-left geometry origin.
        let leftX = CGFloat(x0)
        let rightX = CGFloat(x1)
        let topY = CGFloat(height - 1 - y0)
        let bottomY = CGFloat(height - 1 - y1)

        guard rightX - leftX > 8, topY - bottomY > 8 else { return nil }

        // Force square around the detected band centers.
        let centerX = (leftX + rightX) * 0.5
        let centerY = (topY + bottomY) * 0.5
        let side = max(rightX - leftX, topY - bottomY)
        let half = side * 0.5

        var sqLeft = centerX - half
        var sqRight = centerX + half
        var sqBottom = centerY - half
        var sqTop = centerY + half

        let maxX = CGFloat(width - 1)
        let maxY = CGFloat(height - 1)

        if sqLeft < 0 {
            let delta = -sqLeft
            sqLeft = 0
            sqRight = min(maxX, sqRight + delta)
        }
        if sqRight > maxX {
            let delta = sqRight - maxX
            sqRight = maxX
            sqLeft = max(0, sqLeft - delta)
        }
        if sqBottom < 0 {
            let delta = -sqBottom
            sqBottom = 0
            sqTop = min(maxY, sqTop + delta)
        }
        if sqTop > maxY {
            let delta = sqTop - maxY
            sqTop = maxY
            sqBottom = max(0, sqBottom - delta)
        }

        let quad = BoardQuadrilateral(
            topLeft: CGPoint(x: sqLeft, y: sqTop),
            topRight: CGPoint(x: sqRight, y: sqTop),
            bottomRight: CGPoint(x: sqRight, y: sqBottom),
            bottomLeft: CGPoint(x: sqLeft, y: sqBottom)
        )
        guard isValidSquare(quad: quad, image: image, minSideFraction: 0.6, aspectTolerance: 0.08) else { return nil }
        return quad
    }

    private struct Run {
        let start: Int
        let end: Int
        let mean: Double
        var length: Int { end - start + 1 }
    }

    private static func makeRuns(length: Int, value: (Int) -> Double) -> [Run] {
        guard length > 0 else { return [] }
        let colorTol = 0.05
        var runs: [Run] = []
        var currentStart = 0
        var sum = value(0)
        var count = 1
        var currentMean = sum / Double(count)
        for idx in 1..<length {
            let v = value(idx)
            if abs(v - currentMean) <= colorTol {
                sum += v
                count += 1
                currentMean = sum / Double(count)
            } else {
                let run = Run(start: currentStart, end: idx - 1, mean: currentMean)
                runs.append(run)
                currentStart = idx
                sum = v
                count = 1
                currentMean = v
            }
        }
        runs.append(Run(start: currentStart, end: length - 1, mean: currentMean))
        return runs
    }

    private static func bestCheckeredBand(inRow y: Int, width: Int, luminance: (_ x: Int, _ y: Int) -> Double) -> (start: Int, end: Int)? {
        let runs = makeRuns(length: width) { x in luminance(x, y) }
        return bestAlternatingSegment(in: runs)
    }

    private static func bestCheckeredBand(inColumn x: Int, height: Int, luminance: (_ x: Int, _ y: Int) -> Double) -> (start: Int, end: Int)? {
        let runs = makeRuns(length: height) { y in luminance(x, y) }
        return bestAlternatingSegment(in: runs)
    }

    private static func bestAlternatingSegment(in runs: [Run]) -> (start: Int, end: Int)? {
        guard runs.count >= 8 else { return nil }
        let minContrast = 0.05
        let lengthRatioLimit = 1.7
        var best: (start: Int, end: Int, score: Int)? = nil

        for i in 0..<(runs.count - 1) {
            var minLen = runs[i].length
            var maxLen = runs[i].length
            var endIndex = i
            var scoreLength = runs[i].length
            var runCount = 1

            for j in (i + 1)..<runs.count {
                let prev = runs[j - 1]
                let current = runs[j]
                if abs(current.mean - prev.mean) < minContrast {
                    break
                }
                minLen = Swift.min(minLen, current.length)
                maxLen = Swift.max(maxLen, current.length)
                if Double(maxLen) / Double(minLen) > lengthRatioLimit {
                    break
                }
                endIndex = j
                runCount += 1
                scoreLength += current.length
            }

            if runCount >= 8 {
                let score = runCount * scoreLength
                if best == nil || score > best!.score {
                    best = (runs[i].start, runs[endIndex].end, score)
                }
            }
        }

        if let best = best {
            return (start: best.start, end: best.end)
        }
        return nil
    }

    private static func modeValue(_ values: [Int], binWidth: Int) -> Int? {
        guard !values.isEmpty else { return nil }
        let bin = max(1, binWidth)
        var bins: [Int: [Int]] = [:]
        for v in values {
            let key = v / bin
            bins[key, default: []].append(v)
        }
        guard let (_, bestValues) = bins.max(by: { $0.value.count < $1.value.count }) else { return nil }
        let avg = Double(bestValues.reduce(0, +)) / Double(bestValues.count)
        return Int(avg.rounded())
    }

    private static func isValidSquare(quad: BoardQuadrilateral, image: CGImage, minSideFraction: Double = 0.7, aspectTolerance: Double = 0.08) -> Bool {
        let bb = quad.boundingBox
        let side = min(bb.width, bb.height)
        let minDim = CGFloat(min(image.width, image.height))
        guard side >= minDim * CGFloat(minSideFraction) else { return false }
        let aspect = bb.width / bb.height
        let diff = abs(Double(aspect) - 1.0)
        return diff <= aspectTolerance
    }

    /// Fallback quad using a centered square taking ~96% of the shorter side.
    private static func centeredSquareFallback(image: CGImage) -> BoardQuadrilateral? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let side = min(w, h) * 0.96
        let originX = (w - side) * 0.5
        let originY = (h - side) * 0.5
        guard side > 16 else { return nil }
        let tl = CGPoint(x: originX, y: originY + side)
        let tr = CGPoint(x: originX + side, y: originY + side)
        let br = CGPoint(x: originX + side, y: originY)
        let bl = CGPoint(x: originX, y: originY)
        return BoardQuadrilateral(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }

    /// Fallback that looks for the largest non-dark bounding box via per-row/column luminance.
    private static func luminanceMask(cgImage: CGImage) -> BoardDetectionResult? {
        guard let quad = luminanceMaskQuad(image: cgImage) else { return nil }
        return BoardDetectionResult(quad: quad, confidence: 0.12)
    }

    private static func luminanceMaskQuad(image: CGImage) -> BoardQuadrilateral? {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        let bpr = image.bytesPerRow
        let width = image.width
        let height = image.height

        func meanColumn(_ x: Int) -> Double {
            var sum: Double = 0
            for y in 0..<height {
                let o = y * bpr + x * bpp
                sum += (Double(ptr[o]) + Double(ptr[o + 1]) + Double(ptr[o + 2])) / 3.0
            }
            return sum / Double(height) / 255.0
        }

        func meanRow(_ y: Int) -> Double {
            let row = y * bpr
            var sum: Double = 0
            for x in 0..<width {
                let o = row + x * bpp
                sum += (Double(ptr[o]) + Double(ptr[o + 1]) + Double(ptr[o + 2])) / 3.0
            }
            return sum / Double(width) / 255.0
        }

        var colLuma = Array(repeating: 0.0, count: width)
        for x in 0..<width { colLuma[x] = meanColumn(x) }
        var rowLuma = Array(repeating: 0.0, count: height)
        for y in 0..<height { rowLuma[y] = meanRow(y) }

        guard let colRange = luminanceRange(values: colLuma), let rowRange = luminanceRange(values: rowLuma) else { return nil }

        let padding = Int(Double(min(width, height)) * 0.01)
        var minX = max(0, colRange.start - padding)
        var maxX = min(width - 1, colRange.end + padding)
        var minY = max(0, rowRange.start - padding)
        var maxY = min(height - 1, rowRange.end + padding)

        // Expand to square
        let boxWidth = maxX - minX
        let boxHeight = maxY - minY
        let side = max(boxWidth, boxHeight)
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        let half = side / 2
        minX = max(0, cx - half)
        maxX = min(width - 1, cx + half)
        minY = max(0, cy - half)
        maxY = min(height - 1, cy + half)
        if minX >= maxX || minY >= maxY { return nil }

        let tl = CGPoint(x: CGFloat(minX), y: CGFloat(maxY))
        let tr = CGPoint(x: CGFloat(maxX), y: CGFloat(maxY))
        let br = CGPoint(x: CGFloat(maxX), y: CGFloat(minY))
        let bl = CGPoint(x: CGFloat(minX), y: CGFloat(minY))
        return BoardQuadrilateral(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }

    private static func luminanceRange(values: [Double]) -> (start: Int, end: Int)? {
        guard let minVal = values.min(), let maxVal = values.max() else { return nil }
        let span = maxVal - minVal
        let threshold = minVal + span * 0.1
        guard span > 0.05 else { return nil }

        var start = -1
        var end = -1
        for (i, v) in values.enumerated() {
            if v > threshold {
                start = i
                break
            }
        }
        for i in stride(from: values.count - 1, through: 0, by: -1) {
            if values[i] > threshold {
                end = i
                break
            }
        }
        if start >= 0, end >= start { return (start, end) }
        return nil
    }
}

private struct DetectionConfig {
    let minAspect: Float
    let maxAspect: Float
    let minSize: Float
    let maxObservations: Int
    let minAreaFraction: Float
    let insetFraction: CGFloat
}
