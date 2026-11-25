import CoreGraphics
import Foundation

enum CGImageUtilities {
    static func downsample(_ image: CGImage, maximumDimension: Int) -> CGImage? {
        let maximum = max(1, maximumDimension)
        let current = max(image.width, image.height)
        guard current > maximum else { return image }
        let scale = Double(maximum) / Double(current)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = rgbaContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func grayscaleBytes(_ image: CGImage, side: Int = 32) -> [UInt8] {
        let dimension = max(1, side)
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        return withExtendedLifetime(context) {
            guard let data = context.data, context.bytesPerRow >= dimension else { return [] }
            let rowStride = context.bytesPerRow
            let raw = data.assumingMemoryBound(to: UInt8.self)
            if rowStride == dimension {
                return Array(UnsafeBufferPointer(start: raw, count: dimension * dimension))
            }
            var result = [UInt8]()
            result.reserveCapacity(dimension * dimension)
            for row in 0..<dimension {
                result.append(contentsOf: UnsafeBufferPointer(start: raw.advanced(by: row * rowStride), count: dimension))
            }
            return result
        }
    }

    static func fingerprint(_ image: CGImage) -> ImageFingerprint {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in grayscaleBytes(image) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return ImageFingerprint(value: hash)
    }

    static func crop(_ image: CGImage, rectInLowerLeftPixels rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let topLeft = CGRect(
            x: clipped.minX,
            y: CGFloat(image.height) - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        ).integral
        return image.cropping(to: topLeft)
    }

    private static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
