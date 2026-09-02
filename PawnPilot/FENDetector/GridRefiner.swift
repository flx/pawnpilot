import Foundation
import CoreGraphics

/// Attempts to refine board grid lines based on luminance edges.
nonisolated struct GridRefiner: Sendable {
    func refineGrid(in image: CGImage) -> (xLines: [Int], yLines: [Int])? {
        guard let ptr = image.dataProvider?.data.flatMap({ CFDataGetBytePtr($0) }) else { return nil }
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        let bpr = image.bytesPerRow
        let width = image.width
        let height = image.height
        guard width > 16, height > 16 else { return nil }

        let colLuma = averageLumaColumns(ptr: ptr, bpp: bpp, bpr: bpr, width: width, height: height)
        let rowLuma = averageLumaRows(ptr: ptr, bpp: bpp, bpr: bpr, width: width, height: height)

        let xEdges = edgeProfile(colLuma)
        let yEdges = edgeProfile(rowLuma)

        guard let xs = chooseLines(edges: xEdges, dimension: width),
              let ys = chooseLines(edges: yEdges, dimension: height) else { return nil }
        return (xs, ys)
    }

    private func averageLumaColumns(ptr: UnsafePointer<UInt8>, bpp: Int, bpr: Int, width: Int, height: Int) -> [Double] {
        var result = Array(repeating: 0.0, count: width)
        for x in 0..<width {
            var sum: Double = 0
            for y in 0..<height {
                let o = y * bpr + x * bpp
                sum += luminance(r: ptr[o], g: ptr[o+1], b: ptr[o+2])
            }
            result[x] = sum / Double(height)
        }
        return result
    }

    private func averageLumaRows(ptr: UnsafePointer<UInt8>, bpp: Int, bpr: Int, width: Int, height: Int) -> [Double] {
        var result = Array(repeating: 0.0, count: height)
        for y in 0..<height {
            var sum: Double = 0
            let row = y * bpr
            for x in 0..<width {
                let o = row + x * bpp
                sum += luminance(r: ptr[o], g: ptr[o+1], b: ptr[o+2])
            }
            result[y] = sum / Double(width)
        }
        return result
    }

    private func edgeProfile(_ signal: [Double]) -> [Double] {
        guard signal.count > 2 else { return [] }
        var edges = Array(repeating: 0.0, count: signal.count - 1)
        for i in 0..<edges.count {
            edges[i] = abs(signal[i+1] - signal[i])
        }
        return smooth(edges)
    }

    private func smooth(_ values: [Double]) -> [Double] {
        guard values.count > 4 else { return values }
        var out = values
        for i in 1..<(values.count-1) {
            out[i] = (values[i-1] + values[i] + values[i+1]) / 3.0
        }
        return out
    }

    /// Choose 9 grid lines (0...dimension) by nudging the ideal uniform grid toward local edge maxima.
    /// The adjustment per line is limited to keep crops from drifting and cutting pieces in half.
    private func chooseLines(edges: [Double], dimension: Int) -> [Int]? {
        guard edges.count > 9, dimension > 9 else { return nil }
        let nominalSpacing = Double(dimension) / 8.0
        let searchRadius = max(1, Int(nominalSpacing * 0.15)) // allow small, localized adjustments only
        let minSpacing = Int(nominalSpacing * 0.5)            // prevent collapsed cells
        let maxSpacing = Int(nominalSpacing * 1.5)            // prevent runaway drift

        var lines: [Int] = []
        for i in 0...8 {
            if i == 0 {
                lines.append(0)
                continue
            }
            if i == 8 {
                lines.append(dimension)
                continue
            }
            let ideal = Int(round(Double(i) * nominalSpacing))
            let start = max(0, ideal - searchRadius)
            let end = min(edges.count - 1, ideal + searchRadius)
            var bestIndex = ideal
            var bestValue = -Double.greatestFiniteMagnitude
            for idx in start...end {
                if edges[idx] > bestValue {
                    bestValue = edges[idx]
                    bestIndex = idx
                }
            }
            let clamped = min(max(bestIndex, 1), dimension - 1)
            lines.append(clamped)
        }

        // Validate monotonicity and spacing; reject if refinement collapses or drifts too far.
        for i in 1..<lines.count {
            let delta = lines[i] - lines[i - 1]
            if delta < minSpacing || delta > maxSpacing {
                return nil
            }
        }
        return lines
    }

    private func luminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
        return (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255.0
    }
}
