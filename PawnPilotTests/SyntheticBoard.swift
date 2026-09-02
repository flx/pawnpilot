import CoreGraphics
import Foundation

/// The synthetic detection fixtures, drawn at test time so nothing but code is checked in.
///
/// Every parameter below is load-bearing: the pins in `DetectionFixtureTests` were measured on
/// exactly this output (see `plans/…/detection-off-main-actor.plan.md`, "Fixtures (Tier 0)").
/// An RGBA 8-bit context with premultiplied-last alpha and an opaque fill, a flat margin at
/// `marginGrey`, and 64 squares in the app's greys with a1 — the board's bottom-left square,
/// which is also the CoreGraphics origin corner — dark. No pieces are drawn: the real
/// classifier reads every square of this design as `empty`.
enum SyntheticBoard {

    /// Draws a board of 64 `squareSize` squares whose a1 corner sits at `boardOrigin`
    /// (bottom-left origin, as CoreGraphics counts), on a flat `marginGrey` field.
    static func render(
        size: CGSize,
        boardOrigin: CGPoint,
        squareSize: CGFloat,
        marginGrey: CGFloat = 0.5,
        lightGrey: CGFloat = 0.90,
        darkGrey: CGFloat = 0.65
    ) -> CGImage {
        precondition(
            size.width > 0 && size.height > 0
                && size.width == size.width.rounded() && size.height == size.height.rounded(),
            "SyntheticBoard needs a positive, whole-pixel size; got \(size)"
        )
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("SyntheticBoard could not create a \(width)x\(height) RGBA context")
        }

        context.setFillColor(CGColor(red: marginGrey, green: marginGrey, blue: marginGrey, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for rank in 0..<8 {
            for file in 0..<8 {
                // (file 0, rank 0) is a1, at the bottom left of the board area, and it is dark.
                let grey: CGFloat = (file + rank) % 2 == 0 ? darkGrey : lightGrey
                context.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
                context.fill(CGRect(
                    x: boardOrigin.x + CGFloat(file) * squareSize,
                    y: boardOrigin.y + CGFloat(rank) * squareSize,
                    width: squareSize,
                    height: squareSize
                ))
            }
        }

        guard let image = context.makeImage() else {
            preconditionFailure("SyntheticBoard could not snapshot its \(width)x\(height) context")
        }
        return image
    }

    /// F-edge: 768×768, a 512-px board of 64-px squares at (128, 128) — the edge-detector path.
    static func edge768() -> CGImage {
        render(
            size: CGSize(width: 768, height: 768),
            boardOrigin: CGPoint(x: 128, y: 128),
            squareSize: 64
        )
    }

    /// F-big: 2880×1800, a 1152-px board of 144-px squares centred at (864, 324) — a
    /// Retina-sized capture, and the wall-clock input.
    static func big2880() -> CGImage {
        render(
            size: CGSize(width: 2880, height: 1800),
            boardOrigin: CGPoint(x: 864, y: 324),
            squareSize: 144
        )
    }
}
