import UIKit
import CoreImage
import Combine
import Metal

/// One GPU graph: depth-dependent sampling, small overscan, then the fixed approved outer edge.
@MainActor
final class CallSpatialRenderer {
    let asset: CallSpatialAsset
    private let source: CIImage
    private let depth: CIImage
    private let edges = CallImageOutwardRenderer()
    private var lastKey: String?
    private var lastImage: UIImage?
    private static let kernel: CIKernel? = {
        if MTLCreateSystemDefaultDevice()?.supportsDynamicLibraries == true,
           let kernels = try? CIKernel.kernels(withMetalString: """
            #include <CoreImage/CoreImage.h>
            using namespace metal;
            [[ stitchable ]] float4 sumoSpatial(coreimage::sampler image, coreimage::sampler depth,
                                               float2 movement, coreimage::destination dest) {
                float2 p = dest.coord();
                float d = depth.sample(depth.transform(p)).r;
                return image.sample(image.transform(p + movement * (d - 0.5)));
            }
            """), let kernel = kernels.first { return kernel }
        // Core Image's compatibility compiler supports older iOS 18-capable GPUs.
        return CIKernel(source: """
            kernel vec4 sumoSpatial(sampler image, sampler depth, vec2 movement) {
                vec2 p = destCoord();
                float d = sample(depth, samplerTransform(depth, p)).r;
                return sample(image, samplerTransform(image, p + movement * (d - 0.5)));
            }
            """)
    }()

    init(asset: CallSpatialAsset) {
        self.asset = asset
        source = CIImage(cgImage: asset.image)
        let d = asset.depth
        depth = CIImage(bitmapData: d.values, bytesPerRow: d.width,
            size: CGSize(width: d.width, height: d.height), format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(asset.image.width) / CGFloat(d.width),
                                              y: CGFloat(asset.image.height) / CGFloat(d.height)))
            .clampedToExtent()
            // Smooth only the depth field: abrupt depth jumps can duplicate a subject's outline.
            // The artwork itself never receives this blur, so faces and line art stay sharp.
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(min(asset.image.width, asset.image.height)) * 0.02])
    }

    func image(pose: CGPoint, rect: CGRect, viewport: CGRect, scale: CGFloat = 1,
               amount: CGFloat = 1) -> UIImage? {
        let amount = amount.isFinite ? min(1, max(0, amount)) : 0
        let x = pose.x.isFinite ? (min(1, max(-1, pose.x)) * 300).rounded() / 300 * amount : 0
        let y = pose.y.isFinite ? (min(1, max(-1, pose.y)) * 300).rounded() / 300 * amount : 0
        let zoom = 1 + 0.06 * amount
        let key = "\(x),\(y),\(zoom),\(rect),\(viewport),\(scale)"
        if key == lastKey { return lastImage }
        let extent = source.extent
        let distance = min(extent.width, extent.height) * 0.04
        // Keep the maximum displacement inside the 6% overscan border; no image stretching to fill holes.
        let warped: CIImage
        if x == 0 && y == 0 { warped = source }
        else {
            guard let result = Self.kernel?.apply(extent: extent, roiCallback: { _, rect in
                rect.insetBy(dx: -distance, dy: -distance)
            }, arguments: [source.clampedToExtent(), depth, CIVector(x: x * distance, y: -y * distance)]) else { return nil }
            warped = result
        }
        let zoomed = warped.transformed(by: CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
            tx: extent.midX * (1 - zoom), ty: extent.midY * (1 - zoom))).cropped(to: extent)
        guard let image = edges.renderDynamic(zoomed, in: rect, viewport: viewport, outputScale: scale) else { return nil }
        lastKey = key; lastImage = image
        return image
    }
}

/// Async preparation used by SwiftUI background/framing previews. Closing cancels publication.
@MainActor
final class CallSpatialPresentation: ObservableObject {
    @Published private(set) var renderer: CallSpatialRenderer?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var pose = CGPoint.zero
    @Published private(set) var amount: CGFloat = 1
    private let motionID = UUID()
    private var generation = UUID()

    func load(url: URL?, enabled: Bool) async {
        if !enabled, renderer != nil, UIApplication.shared.applicationState == .active {
            CallSpatialMotion.shared.release(motionID)
            let expected = generation, start = amount
            for step in 1...8 {
                if Task.isCancelled || expected != generation { return }
                amount = start * (1 - CGFloat(step) / 8)
                try? await Task.sleep(for: .milliseconds(32))
            }
        }
        stop()
        guard enabled, let url else { return }
        let expected = generation
        isLoading = true
        do {
            let asset = try await CallSpatialDepth.shared.prepare(url: url)
            try Task.checkCancellation()
            guard generation == expected else { return }
            amount = 0; renderer = CallSpatialRenderer(asset: asset); isLoading = false
            CallSpatialMotion.shared.observe(motionID) { [weak self] in
                self?.pose = CallSpatialMotion.shared.pose
            }
            for step in 1...8 {
                if Task.isCancelled || generation != expected { return }
                amount = CGFloat(step) / 8
                try? await Task.sleep(for: .milliseconds(32))
            }
        } catch is CancellationError {
            if generation == expected { isLoading = false }
        } catch {
            guard generation == expected else { return }
            isLoading = false; self.error = InterfaceLocalization.text("空间效果暂不可用，已保留原画。\(error.localizedDescription)")
        }
    }

    func stop() {
        generation = UUID(); renderer = nil; error = nil; isLoading = false; pose = .zero
        CallSpatialMotion.shared.release(motionID)
    }
}
