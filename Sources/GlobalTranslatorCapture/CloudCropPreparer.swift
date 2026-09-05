import CoreGraphics
import Foundation

public struct PreparedCloudCrop: @unchecked Sendable {
    public let regionID: UUID
    public let image: CGImage
    public let screenFrame: CGRect
    public let confidence: Float

    public init(regionID: UUID, image: CGImage, screenFrame: CGRect, confidence: Float) {
        self.regionID = regionID
        self.image = image
        self.screenFrame = screenFrame
        self.confidence = confidence
    }
}

public struct CloudCropPreparer: Sendable {
    public let maximumCrops: Int
    public let maximumDimension: Int
    public let lowConfidenceThreshold: Float

    public init(
        maximumCrops: Int = 8,
        maximumDimension: Int = 1_024,
        lowConfidenceThreshold: Float = 0.65
    ) {
        self.maximumCrops = min(max(maximumCrops, 0), 8)
        self.maximumDimension = min(max(maximumDimension, 1), 1_024)
        self.lowConfidenceThreshold = min(max(lowConfidenceThreshold, 0), 1)
    }

    public func prepare(
        image: CGImage,
        regions: [TextRegion],
        windowFrame: CGRect
    ) -> [PreparedCloudCrop] {
        regions.lazy
            .filter { $0.confidence < lowConfidenceThreshold }
            .prefix(maximumCrops)
            .compactMap { region in
                let imageRect = CoordinateConverter.screenFrameToImageRect(
                    region.screenFrame,
                    windowFrame: windowFrame,
                    imageSize: CGSize(width: image.width, height: image.height)
                )
                guard let cropped = CGImageUtilities.crop(image, rectInLowerLeftPixels: imageRect),
                      let prepared = CGImageUtilities.downsample(cropped, maximumDimension: maximumDimension) else { return nil }
                return PreparedCloudCrop(
                    regionID: region.id,
                    image: prepared,
                    screenFrame: region.screenFrame,
                    confidence: region.confidence
                )
            }
    }
}
