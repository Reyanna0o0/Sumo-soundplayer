import SwiftUI
import UIKit

struct CoverImageView: View {
    let path: String?
    var cornerRadius: CGFloat = 12
    var contentMode: ContentMode = .fill
    var maxPixels = 480
    var framingFraction: CGFloat = 0

    var showsOriginal = false
    var playerCoverMode: PlayerCoverMode? = nil
    @AppStorage(CoverPrivacy.settingKey) private var privacyEnabled = false

    private struct Request: Equatable {
        let path: String?
        let size: Int
        let obscured: Bool
    }
    private var request: Request {
        Request(path: path, size: maxPixels, obscured: privacyEnabled && !showsOriginal)
    }

    @State private var loaded: Request?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let playerCoverMode, playerCoverMode != .original {
                AppTheme.painted(Color(uiColor: .tertiarySystemGroupedBackground), AppTheme.groupedCard)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { artwork(playerCoverMode == .fit4x3 ? .fit : .fill) }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else if framingFraction > 0 {
                GeometryReader { canvas in
                    let framed = CoverFraming.size(image: CGSize(width: imageRatio, height: 1),
                                                   container: canvas.size, fraction: framingFraction)
                    artwork(contentMode)
                        .frame(width: framed.width, height: framed.height)
                        .position(x: canvas.size.width / 2, y: canvas.size.height / 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else if playerCoverMode == .original || contentMode == .fit {
                artwork(.fit)
                    .aspectRatio(imageRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                Color.clear
                    .overlay { artwork(contentMode) }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .task(id: request) {
            let asked = request
            guard let path = asked.path else { image = nil; loaded = nil; return }
            let result = await CoverCache.shared.image(at: path, maxPixels: asked.size, obscured: asked.obscured)
            guard !Task.isCancelled else { return }
            image = result
            loaded = asked
        }
        .accessibilityHidden(true)
    }

    private var imageRatio: CGFloat {
        if loaded == request, let image { return image.size.width / max(1, image.size.height) }
        return 4 / 3
    }

    @ViewBuilder private func artwork(_ contentMode: ContentMode) -> some View {
        if loaded == request, let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
        } else {
            LinearGradient(colors: [Color(red: 0.35, green: 0.28, blue: 0.39),
                                    Color(red: 0.16, green: 0.13, blue: 0.21)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay { Image(systemName: "music.note").font(.largeTitle.weight(.light)).foregroundStyle(.white.opacity(0.75)) }
        }
    }
}
