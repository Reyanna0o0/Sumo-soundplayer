import SwiftUI

/// 三个区域一起铺满圆角栏，标题后的空白也能展开播放器。
struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerController
    @State private var showQueue = false
    @ScaledMetric(relativeTo: .subheadline) private var trackTitleSize: CGFloat = 14
    private let controlSize: CGFloat = 44
    private let endInset: CGFloat = 8

    var body: some View {
        if let item = player.currentItem {
            HStack(spacing: 0) {
                Button {
                    player.isPlayerSheetPresented = true
                } label: {
                    HStack(spacing: 10) {
                        CoverImageView(path: player.currentCoverPath, cornerRadius: 5, maxPixels: 160)
                            .frame(width: 48, height: 36)
                            .frame(height: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.trackTitle)
                                .font(.system(size: trackTitleSize, weight: .semibold))
                                .lineLimit(1)
                            Text(player.currentWorkTitle)
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(1)
                            progressLine
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, endInset)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 52, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("\(item.trackTitle)，\(player.currentWorkTitle)")
                .accessibilityHint("展开播放器")
                .accessibilityIdentifier("expandMiniPlayer")

                Button(action: player.togglePlayPause) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(AppTheme.isPurple ? AnyShapeStyle(AppTheme.iconTint) : AnyShapeStyle(.primary))
                        .offset(x: 4)
                        .frame(width: controlSize)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(player.isPlaying ? L10n.text("暂停") : L10n.text("播放"))
                .accessibilityIdentifier("miniPlayPause")

                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.isPurple ? AnyShapeStyle(AppTheme.iconTint) : AnyShapeStyle(.primary))
                        .frame(width: controlSize)
                        .padding(.trailing, endInset)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("当前播放队列")
                .accessibilityIdentifier("miniQueue")
                .disabled(!player.hasQueue)
            }
            .fixedSize(horizontal: false, vertical: true)
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .background {
                if AppTheme.isPurple {
                    Capsule().fill(AppTheme.purpleMiniSurface)
                        .overlay { Capsule().strokeBorder(AppTheme.purplePlaybackIndicator.opacity(0.12), lineWidth: 1) }
                        .shadow(color: AppTheme.shadow.opacity(0.18), radius: 5, y: 2)
                        .allowsHitTesting(false)
                } else if #available(iOS 26, *) {
                    Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
                        .allowsHitTesting(false)
                } else {
                    Capsule().fill(.regularMaterial)
                        .overlay { Capsule().strokeBorder(.primary.opacity(0.1)) }
                        .shadow(color: AppTheme.shadow.opacity(0.12), radius: 5, y: 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 16)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .porcelainSheet(isPresented: $showQueue) { PlaybackQueueSheet() }
        }
    }

    private var progressLine: some View {
        GeometryReader { bounds in
            let ratio = player.durationMS > 0 ? CGFloat(player.positionMS) / CGFloat(player.durationMS) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.17))
                Capsule().fill(AppTheme.isPurple ? AnyShapeStyle(AppTheme.purplePlaybackIndicator) : AnyShapeStyle(.tint))
                    .frame(width: bounds.size.width * min(max(ratio, 0), 1))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
