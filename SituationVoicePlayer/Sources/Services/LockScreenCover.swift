import MediaPlayer
import UIKit

enum CoverPrivacy {
    static let settingKey = "obscureWorkCovers"
    static var publicTitle: String { InterfaceLocalization.text("每日晨读：净化心灵的美文300篇......") }
}

@MainActor
final class LockScreenCover {
    private struct Request: Equatable {
        let path: String?
        let obscured: Bool
    }

    private var request: Request?
    private var artwork: MPMediaItemArtwork?
    private var loading: Task<Void, Never>?

    func clear() {
        loading?.cancel()
        request = nil
        artwork = nil
    }

    func current(path: String?, obscured: Bool, onChange: @escaping @MainActor () -> Void) -> MPMediaItemArtwork? {
        let next = Request(path: path, obscured: obscured)
        guard next != request else { return artwork }
        loading?.cancel()
        request = next
        // Replace the previous frame immediately, even if the new cover is on iCloud or unavailable.
        artwork = obscured ? Self.neutralArtwork : nil
        if let path {
            loading = Task { [weak self] in
                let image = await CoverCache.shared.image(at: path, maxPixels: 600, obscured: obscured)
                guard !Task.isCancelled, let self, self.request == next, let image else { return }
                self.artwork = Self.makeArtwork(image)
                onChange()
            }
        }
        return artwork
    }

    private static let neutralArtwork: MPMediaItemArtwork = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor(red: 0.30, green: 0.27, blue: 0.34, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return makeArtwork(image)
    }()

    private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { requested in
            guard requested.width > 0, requested.height > 0,
                  requested.width <= 2048, requested.height <= 2048 else { return image }
            let scale = max(requested.width / image.size.width, requested.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let frame = CGRect(x: (requested.width - size.width) / 2, y: (requested.height - size.height) / 2,
                               width: size.width, height: size.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: requested, format: format).image { context in
                context.cgContext.interpolationQuality = .high
                image.draw(in: frame)
            }
        }
    }
}
