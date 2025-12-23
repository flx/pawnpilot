import Foundation
import CoreGraphics

/// Utility to overwrite noisy borders with the estimated background color.
struct ImageSanitizer {
    static func sanitize(image: CGImage, marginFraction: Double = 0.05) -> CGImage {
        let width = image.width
        let height = image.height
        let margin = max(1, Int(Double(min(width, height)) * marginFraction))
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return image
        }
        let color = backgroundColor(for: image)
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Overwrite outer border
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: height - margin, width: width, height: margin)) // Top
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: margin)) // Bottom
        ctx.fill(CGRect(x: 0, y: margin, width: margin, height: height - margin * 2)) // Left
        ctx.fill(CGRect(x: width - margin, y: margin, width: margin, height: height - margin * 2)) // Right
        return ctx.makeImage() ?? image
    }

    private static func backgroundColor(for image: CGImage) -> CGColor {
        guard
            let data = image.dataProvider?.data,
            let ptr = CFDataGetBytePtr(data)
        else { return CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0) }
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0) }
        let bpr = image.bytesPerRow

        let band = max(2, min(image.width, image.height) / 16)
        let offset = max(1, Int(Double(min(image.width, image.height)) * 0.08))

        var samples: [[Double]] = []
        // Horizontal bands just inside the border
        if let top = meanBand(ptr: ptr, bpp: bpp, bpr: bpr, x0: offset, x1: image.width - offset, y0: image.height - offset - band, y1: image.height - offset) {
            samples.append(top)
        }
        if let bottom = meanBand(ptr: ptr, bpp: bpp, bpr: bpr, x0: offset, x1: image.width - offset, y0: offset, y1: offset + band) {
            samples.append(bottom)
        }
        // Vertical bands
        if let left = meanBand(ptr: ptr, bpp: bpp, bpr: bpr, x0: offset, x1: offset + band, y0: offset, y1: image.height - offset) {
            samples.append(left)
        }
        if let right = meanBand(ptr: ptr, bpp: bpp, bpr: bpr, x0: image.width - offset - band, x1: image.width - offset, y0: offset, y1: image.height - offset) {
            samples.append(right)
        }

        guard !samples.isEmpty else { return CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0) }

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            if sorted.count % 2 == 0 {
                return (sorted[mid - 1] + sorted[mid]) / 2.0
            } else {
                return sorted[mid]
            }
        }

        let reds = samples.map { $0[0] }
        let greens = samples.map { $0[1] }
        let blues = samples.map { $0[2] }
        return CGColor(
            red: median(reds) / 255.0,
            green: median(greens) / 255.0,
            blue: median(blues) / 255.0,
            alpha: 1.0
        )
    }

    private static func meanBand(ptr: UnsafePointer<UInt8>, bpp: Int, bpr: Int, x0: Int, x1: Int, y0: Int, y1: Int) -> [Double]? {
        guard x1 > x0, y1 > y0 else { return nil }
        var r: Double = 0, g: Double = 0, b: Double = 0
        var count = 0
        for y in y0..<y1 {
            let row = y * bpr
            for x in x0..<x1 {
                let o = row + x * bpp
                r += Double(ptr[o])
                g += Double(ptr[o + 1])
                b += Double(ptr[o + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let scale = 1.0 / Double(count)
        return [r * scale, g * scale, b * scale]
    }
}
