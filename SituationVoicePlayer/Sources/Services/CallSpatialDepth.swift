import Foundation
import UIKit
import CoreML
import CoreImage
import CryptoKit
import ImageIO
import Vision

/// Only derived depth is cached. Original images and saved framing are never written here.
actor CallSpatialDepth {
    static let shared = CallSpatialDepth()
    static let modelVersion = "depth-anything-v2-small-f16-cfef6f6-v1"
    private let cacheRoot: URL
    private let modelURL: URL?
    private(set) var predictionCount = 0
    private(set) var lastPreparationSeconds: Double = 0

    init(cacheRoot: URL? = nil, modelURL: URL? = nil) {
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallSpatialDepth-v1", isDirectory: true)
        self.modelURL = modelURL ?? Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc")
    }

    struct Depth: Codable, Sendable {
        let version: String
        let imageHash: String
        let width: Int
        let height: Int
        let values: Data
        var isValid: Bool {
            version == CallSpatialDepth.modelVersion && width > 0 && height > 0
                && width <= 2048 && height <= 2048 && values.count == width * height
        }
    }

    func prepare(url: URL) throws -> CallSpatialAsset {
        let started = CFAbsoluteTimeGetCurrent()
        defer { lastPreparationSeconds = CFAbsoluteTimeGetCurrent() - started }
        try Task.checkCancellation()
        guard url.isFileURL else { throw SpatialError.unreadable }
        let original = WorkAssetImporter.originalImageForCropping(at: url.path)
        let bytes = try Data(contentsOf: original, options: .mappedIfSafe)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard let image = Self.decodedImage(at: original) else { throw SpatialError.unreadable }
        let file = cacheRoot.appendingPathComponent(hash + ".depth")
        if let data = try? Data(contentsOf: file), data.count < 8_000_000,
           let depth = try? PropertyListDecoder().decode(Depth.self, from: data), depth.isValid,
           depth.imageHash == hash {
            try Task.checkCancellation()
            return CallSpatialAsset(image: image, depth: depth, cacheHit: true)
        }
        guard let modelURL else { throw SpatialError.missingModel }
        let depth: Depth = try autoreleasepool {
            let configuration = MLModelConfiguration()
            #if targetEnvironment(simulator)
            configuration.computeUnits = .cpuOnly
            #else
            configuration.computeUnits = .cpuAndNeuralEngine
            #endif
            // The model is released after one prediction; subsequent presentations use the tiny depth file.
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            guard let input = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
                  let constraint = input.value.imageConstraint else { throw SpatialError.invalidModel }
            let value = try MLFeatureValue(cgImage: image, pixelsWide: constraint.pixelsWide,
                pixelsHigh: constraint.pixelsHigh, pixelFormatType: constraint.pixelFormatType,
                options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
            try Task.checkCancellation()
            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: value]))
            predictionCount += 1
            if let buffer = result.featureNames.compactMap({ result.featureValue(for: $0)?.imageBufferValue }).first {
                return try Self.normalized(buffer, hash: hash)
            }
            if let array = result.featureNames.compactMap({ result.featureValue(for: $0)?.multiArrayValue }).first {
                return try Self.normalized(array, hash: hash)
            }
            throw SpatialError.invalidModel
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(depth).write(to: file, options: .atomic)
        pruneCache(keeping: file)
        return CallSpatialAsset(image: image, depth: depth, cacheHit: false)
    }

    static func normalized(_ array: MLMultiArray, hash: String) throws -> Depth {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard shape.count >= 2, shape.dropLast(2).allSatisfy({ $0 == 1 }),
              let width = shape.last, width > 1, width <= 2048 else { throw SpatialError.invalidModel }
        let height = shape[shape.count - 2]
        guard height > 1, height <= 2048 else { throw SpatialError.invalidModel }
        let row = strides[strides.count - 2], col = strides[strides.count - 1]
        var values = [Float](); values.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = array[y * row + x * col].floatValue
                guard v.isFinite else { throw SpatialError.invalidDepth }
                values.append(v)
            }
        }
        return try normalized(values, width: width, height: height, hash: hash)
    }

    static func normalized(_ buffer: CVPixelBuffer, hash: String) throws -> Depth {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 1, height > 1, width <= 2048, height <= 2048,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw SpatialError.invalidDepth }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpatialError.invalidDepth }
        let row = CVPixelBufferGetBytesPerRow(buffer), format = CVPixelBufferGetPixelFormatType(buffer)
        var values = [Float](); values.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value: Float
                switch format {
                case kCVPixelFormatType_OneComponent16Half:
                    value = Float(Float16(bitPattern: base.load(fromByteOffset: y * row + x * 2, as: UInt16.self)))
                case kCVPixelFormatType_OneComponent32Float:
                    value = base.load(fromByteOffset: y * row + x * 4, as: Float.self)
                case kCVPixelFormatType_OneComponent8:
                    value = Float(base.load(fromByteOffset: y * row + x, as: UInt8.self))
                default: throw SpatialError.invalidModel
                }
                guard value.isFinite else { throw SpatialError.invalidDepth }; values.append(value)
            }
        }
        return try normalized(values, width: width, height: height, hash: hash)
    }

    private static func normalized(_ values: [Float], width: Int, height: Int, hash: String) throws -> Depth {
        let sorted = values.sorted(), low = sorted[values.count / 100], high = sorted[values.count * 99 / 100]
        guard high - low > max(0.00001, abs(high) * 0.0001) else { throw SpatialError.invalidDepth }
        let normalized = values.map { UInt8((max(0, min(1, ($0 - low) / (high - low))) * 255).rounded()) }
        return Depth(version: modelVersion, imageHash: hash, width: width, height: height, values: Data(normalized))
    }

    nonisolated static func decodedImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1440, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    func cacheBytes() -> Int64 {
        files().reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clearCache() throws {
        // Enumerate our own derived files only. Never remove a photo or a parent directory.
        for url in files() { try FileManager.default.removeItem(at: url) }
    }

    private func files() -> [URL] {
        guard (try? cacheRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: cacheRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { url in
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return url.pathExtension == "depth" && v?.isRegularFile == true && v?.isSymbolicLink != true
            }
    }

    private func pruneCache(keeping current: URL) {
        var total = cacheBytes()
        let entries = files().filter { $0 != current }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
              < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for url in entries where total > 32 * 1024 * 1024 {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }

    enum SpatialError: LocalizedError {
        case unreadable, missingModel, invalidModel, invalidDepth
        var errorDescription: String? {
            switch self {
            case .unreadable: return InterfaceLocalization.text("无法读取原图片，暂时显示原画。")
            case .missingModel, .invalidModel: return InterfaceLocalization.text("空间效果暂不可用，暂时显示原画。")
            case .invalidDepth: return InterfaceLocalization.text("这张图片的前后层次不够明确，暂时显示原画。")
            }
        }
    }
}

/// Immutable downsampled textures can be passed from the background preparation actor.
final class CallSpatialAsset: @unchecked Sendable {
    let image: CGImage
    let depth: CallSpatialDepth.Depth
    let cacheHit: Bool
    init(image: CGImage, depth: CallSpatialDepth.Depth, cacheHit: Bool) {
        self.image = image; self.depth = depth; self.cacheHit = cacheHit
    }
}
