import CoreImage
import ImageIO
import UIKit

actor CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, UIImage>()

    private let blurContext = CIContext(options: [.cacheIntermediates: false])

    init() { cache.totalCostLimit = 48 * 1024 * 1024 }

    func image(at path: String, maxPixels: Int, obscured: Bool) -> UIImage? {
        let size = obscured ? 24 : maxPixels
        let key = "\(obscured):\(size):\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: size
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let pixels: CGImage
        if obscured {
            // Only the obscured pixels may leave the cache for a private thumbnail or remote display.
            let input = CIImage(cgImage: thumbnail)
            let blur = input.clampedToExtent().applyingGaussianBlur(sigma: CGFloat(max(thumbnail.width, thumbnail.height)) * 0.18)
            guard let rendered = blurContext.createCGImage(blur, from: input.extent) else { return nil }
            pixels = rendered
        } else {
            pixels = thumbnail
        }
        let image = UIImage(cgImage: pixels)
        cache.setObject(image, forKey: key, cost: pixels.bytesPerRow * pixels.height)
        return image
    }
}
