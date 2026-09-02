import Foundation
import CoreGraphics

/// Utility for mapping normalized board coordinates to image space.
nonisolated public enum BoardGeometry {
    /// Bilinear interpolation mapping from normalized board coordinates (u,v in 0...1, origin bottom-left)
    /// to image pixel coordinates using the detected quadrilateral.
    public static func mapPoint(u: CGFloat, v: CGFloat, quad: BoardQuadrilateral) -> CGPoint {
        let bl = quad.bottomLeft
        let br = quad.bottomRight
        let tl = quad.topLeft
        let tr = quad.topRight
        // Bilinear blend
        let bottom = CGPoint(x: bl.x + (br.x - bl.x) * u, y: bl.y + (br.y - bl.y) * u)
        let top = CGPoint(x: tl.x + (tr.x - tl.x) * u, y: tl.y + (tr.y - tl.y) * u)
        return CGPoint(x: bottom.x + (top.x - bottom.x) * v, y: bottom.y + (top.y - bottom.y) * v)
    }

    /// Returns polygon (4 points) for a square at file/rank in image coordinates.
    public static func squarePolygon(file: Int, rank: Int, quad: BoardQuadrilateral) -> [CGPoint] {
        let u0 = CGFloat(file) / 8.0
        let u1 = CGFloat(file + 1) / 8.0
        let v0 = CGFloat(rank) / 8.0
        let v1 = CGFloat(rank + 1) / 8.0
        return [
            mapPoint(u: u0, v: v1, quad: quad), // top-left
            mapPoint(u: u1, v: v1, quad: quad), // top-right
            mapPoint(u: u1, v: v0, quad: quad), // bottom-right
            mapPoint(u: u0, v: v0, quad: quad)  // bottom-left
        ]
    }
}
