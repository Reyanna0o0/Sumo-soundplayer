import SwiftUI
import UIKit
import CoreImage
import ImageIO

/// Feather only edges that are visible inside the viewport; full-bleed images
/// stay sharp. The same geometry is used by the editor and the PiP renderer.
enum CallImageEdgeBlend {
    static func widths(image: CGRect, viewport: CGRect) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        let feather = min(24, min(viewport.width, viewport.height) * 0.055,
                          min(image.width, image.height) * 0.12)
        return (image.minX > viewport.minX + 1 ? feather : 0,
                image.maxX < viewport.maxX - 1 ? feather : 0,
                image.minY > viewport.minY + 1 ? feather : 0,
                image.maxY < viewport.maxY - 1 ? feather : 0)
    }

    static func draw(_ image: UIImage, in rect: CGRect, viewport: CGRect, context: CGContext) {
        let edges = widths(image: rect, viewport: viewport)
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        let colors = [UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            let strips: [(CGFloat, CGRect, CGPoint, CGPoint)] = [
                (edges.left, CGRect(x: rect.minX, y: rect.minY, width: edges.left, height: rect.height),
                 CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.minX + edges.left, y: rect.midY)),
                (edges.right, CGRect(x: rect.maxX - edges.right, y: rect.minY, width: edges.right, height: rect.height),
                 CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX - edges.right, y: rect.midY)),
                (edges.top, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: edges.top),
                 CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY + edges.top)),
                (edges.bottom, CGRect(x: rect.minX, y: rect.maxY - edges.bottom, width: rect.width, height: edges.bottom),
                 CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY - edges.bottom))]
            for (width, strip, start, end) in strips where width > 0 {
                context.saveGState(); context.clip(to: strip); context.setBlendMode(.destinationIn)
                context.drawLinearGradient(gradient, start: start, end: end, options: [])
                context.restoreGState()
            }
        }
        context.endTransparencyLayer(); context.restoreGState()
    }
}

struct CallImageEdgeMask: View {
    let image: CGRect
    let viewport: CGRect
    var body: some View {
        let e = CallImageEdgeBlend.widths(image: image, viewport: viewport)
        LinearGradient(stops: [
            .init(color: e.left > 0 ? .clear : .white, location: 0),
            .init(color: .white, location: e.left / max(1, image.width)),
            .init(color: .white, location: 1 - e.right / max(1, image.width)),
            .init(color: e.right > 0 ? .clear : .white, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
        .mask(LinearGradient(stops: [
            .init(color: e.top > 0 ? .clear : .white, location: 0),
            .init(color: .white, location: e.top / max(1, image.height)),
            .init(color: .white, location: 1 - e.bottom / max(1, image.height)),
            .init(color: e.bottom > 0 ? .clear : .white, location: 1)
        ], startPoint: .top, endPoint: .bottom))
    }
}

/// The approved still-image treatment: 32 points inward / 104 outward / 20 blur,
/// at a 390 x 844 reference viewport. Video keeps the lightweight existing mask.
/// Both the framing editor and call/PiP use this compositor, including its cache.
@MainActor
final class CallImageOutwardRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private var sourceImage: UIImage?
    private var source: CIImage?
    private var lastKey: Key?
    private var lastResult: UIImage?
    private var dynamicKey: Key?
    private var dynamicMasks: (detail: CIImage, opacity: CIImage)?

    private struct Key: Equatable {
        let rect: CGRect
        let viewport: CGRect
        let scale: CGFloat
    }

    func reset() {
        sourceImage = nil; source = nil; lastKey = nil; lastResult = nil
        dynamicKey = nil; dynamicMasks = nil
    }

    static func hasExposedEdges(_ rect: CGRect, in viewport: CGRect) -> Bool {
        rect.minX > viewport.minX + 1 || rect.maxX < viewport.maxX - 1
            || rect.minY > viewport.minY + 1 || rect.maxY < viewport.maxY - 1
    }

    /// Returns a transparent viewport-sized overlay; existing black/blur fill stays behind it.
    func render(_ image: UIImage, in rect: CGRect, viewport: CGRect,
                outputScale: CGFloat = 1) -> UIImage? {
        guard [rect.minX, rect.minY, rect.width, rect.height,
               viewport.minX, viewport.minY, viewport.width, viewport.height, outputScale]
                .allSatisfy({ $0.isFinite }),
              rect.width > 0, rect.height > 0, viewport.width > 0, viewport.height > 0,
              outputScale > 0, Self.hasExposedEdges(rect, in: viewport) else { return nil }
        let scale = min(outputScale, 1920 / max(viewport.width, viewport.height))
        let key = Key(rect: rect, viewport: viewport, scale: scale)
        if sourceImage === image, lastKey == key { return lastResult }
        if sourceImage !== image {
            reset()
            guard let cgImage = image.cgImage else { return nil }
            let oriented = CIImage(cgImage: cgImage).oriented(forExifOrientation: image.imageOrientation.exifValue)
            source = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX,
                                                                y: -oriented.extent.minY))
            sourceImage = image
        }
        guard let source, !source.extent.isEmpty else { return nil }
        let width = max(1, Int(ceil(viewport.width * scale)))
        let height = max(1, Int(ceil(viewport.height * scale)))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // Core Image's origin is bottom-left; UIKit/framing gestures use top-left.
        let placement = CGRect(x: (rect.minX - viewport.minX) * scale,
                               y: (viewport.maxY - rect.maxY) * scale,
                               width: rect.width * scale, height: rect.height * scale)
        let displayScale = min(viewport.width / 390, viewport.height / 844)
        let inner = min(32 * displayScale, min(rect.width, rect.height) * 0.23) * scale
        let outer = 104 * displayScale * scale
        let blur = 20 * displayScale * scale
        let original = source.transformed(by: CGAffineTransform(scaleX: placement.width / source.extent.width,
                                                               y: placement.height / source.extent.height))
            .transformed(by: CGAffineTransform(translationX: placement.minX, y: placement.minY))
        // Repeat boundary pixels rather than putting an enlarged duplicate portrait behind the image.
        let extended = original.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: bounds)
        let masks = Self.masks(width: width, height: height, rect: placement,
                               inner: inner, outer: outer, tolerance: scale)
        let softened = original.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: extended, kCIInputMaskImageKey: masks.detail
        ]).cropped(to: bounds)
        let clear = CIImage(color: .clear).cropped(to: bounds)
        let result = softened.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: masks.opacity
        ]).cropped(to: bounds)
        let colorSpace = image.cgImage?.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let rendered = Self.context.createCGImage(result, from: bounds, format: .RGBA8,
                                                        colorSpace: colorSpace) else { return nil }
        let output = UIImage(cgImage: rendered, scale: scale, orientation: .up)
        lastKey = key; lastResult = output
        return output
    }

    /// Dynamic spatial source; only geometry masks are cached, never reallocated for a new attitude.
    func renderDynamic(_ image: CIImage, in rect: CGRect, viewport: CGRect,
                       outputScale: CGFloat = 1) -> UIImage? {
        guard [rect.minX, rect.minY, rect.width, rect.height, viewport.minX, viewport.minY,
               viewport.width, viewport.height, outputScale].allSatisfy({ $0.isFinite }),
              rect.width > 0, rect.height > 0, viewport.width > 0, viewport.height > 0,
              outputScale > 0, !image.extent.isEmpty, !image.extent.isInfinite else { return nil }
        let scale = min(outputScale, 1440 / max(viewport.width, viewport.height))
        let width = max(1, Int(ceil(viewport.width * scale))), height = max(1, Int(ceil(viewport.height * scale)))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let placement = CGRect(x: (rect.minX - viewport.minX) * scale,
            y: (viewport.maxY - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let original = normalized.transformed(by: CGAffineTransform(scaleX: placement.width / image.extent.width,
            y: placement.height / image.extent.height)).transformed(by: CGAffineTransform(translationX: placement.minX, y: placement.minY))
        var result = original.cropped(to: bounds)
        if Self.hasExposedEdges(rect, in: viewport) {
            let key = Key(rect: rect, viewport: viewport, scale: scale)
            let displayScale = min(viewport.width / 390, viewport.height / 844)
            if dynamicKey != key || dynamicMasks == nil {
                dynamicMasks = Self.masks(width: width, height: height, rect: placement,
                    inner: min(32 * displayScale, min(rect.width, rect.height) * 0.23) * scale,
                    outer: 104 * displayScale * scale, tolerance: scale)
                dynamicKey = key
            }
            guard let masks = dynamicMasks else { return nil }
            let extended = original.clampedToExtent().applyingFilter("CIGaussianBlur",
                parameters: [kCIInputRadiusKey: 20 * displayScale * scale]).cropped(to: bounds)
            result = original.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: extended, kCIInputMaskImageKey: masks.detail
            ]).cropped(to: bounds).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: bounds),
                kCIInputMaskImageKey: masks.opacity
            ]).cropped(to: bounds)
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let output = Self.context.createCGImage(result, from: bounds, format: .RGBA8, colorSpace: space) else { return nil }
        return UIImage(cgImage: output, scale: scale, orientation: .up)
    }

    private static func smoother(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private static func masks(width: Int, height: Int, rect: CGRect,
                              inner: CGFloat, outer: CGFloat, tolerance: CGFloat)
        -> (detail: CIImage, opacity: CIImage) {
        func axis(count: Int, lower: CGFloat, upper: CGFloat) -> [(Double, Double)] {
            (0..<count).map { index in
                let position = CGFloat(index) + 0.5
                var detail = 1.0, opacity = 1.0
                if lower > tolerance {
                    detail *= smoother(Double((position - lower) / inner))
                    opacity *= smoother(Double((position - lower + outer) / (inner + outer)))
                }
                if upper < CGFloat(count) - tolerance {
                    detail *= smoother(Double((upper - position) / inner))
                    opacity *= smoother(Double((upper - position + outer) / (inner + outer)))
                }
                return (detail, opacity)
            }
        }
        let x = axis(count: width, lower: rect.minX, upper: rect.maxX)
        let y = axis(count: height, lower: rect.minY, upper: rect.maxY)
        // Compose two 1-D ramps on the GPU instead of walking every output pixel
        // on the main thread while the user drags or pinches the framing editor.
        func mask(horizontal: [Double], vertical: [Double]) -> CIImage {
            let columns = horizontal.map { UInt8((255 * $0).rounded()) }
            // Bitmap rows are top-first; the axis calculations use CI's bottom-left origin.
            let rows = vertical.reversed().map { UInt8((255 * $0).rounded()) }
            let h = CIImage(bitmapData: Data(columns), bytesPerRow: width,
                            size: CGSize(width: width, height: 1), format: .L8, colorSpace: nil)
                .clampedToExtent()
            let v = CIImage(bitmapData: Data(rows), bytesPerRow: 1,
                            size: CGSize(width: 1, height: height), format: .L8, colorSpace: nil)
                .clampedToExtent()
            return h.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: v])
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (mask(horizontal: x.map(\.0), vertical: y.map(\.0)),
                mask(horizontal: x.map(\.1), vertical: y.map(\.1)))
    }
}

private extension UIImage.Orientation {
    var exifValue: Int32 {
        switch self {
        case .up: return 1
        case .upMirrored: return 2
        case .down: return 3
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .right: return 6
        case .rightMirrored: return 7
        case .left: return 8
        @unknown default: return 1
        }
    }
}
