import SwiftUI

/// 封面墙里的一个作品卡片
struct WorkCardView: View {
    let work: WorkRecord
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { slot in
                cover
                    .frame(width: slot.size.width * 0.97, height: slot.size.height * 0.97)
                    .position(x: slot.size.width / 2, y: slot.size.height / 2)
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 0) {
                Text(work.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(AppTheme.primaryText)

                Text(work.subtitle.replacingOccurrences(of: "、", with: "/"))
                    .font(.caption2)
                    .lineLimit(1, reservesSpace: true)
                    .foregroundStyle(AppTheme.secondaryText)

                HStack(spacing: 4) {
                    Text(work.mediaCountText)
                    if work.totalDurationMS > 0 {
                        Text("·")
                        Text(formattedDuration)
                    }
                }
                .font(.caption2)
                .foregroundStyle(AppTheme.tertiaryText)
            }
        }
    }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            CoverImageView(path: work.resolvedCoverPath ?? work.coverPath)

            if work.favorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.usesDarkPalette ? AppTheme.iconTint : .white, AppTheme.painted(.pink, AppTheme.iconTint))
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            WorkFileLinkBadge(work: work, store: store).padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            if work.hasResumePoint {
                // 听了一半的标记
                HStack(spacing: 3) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9))
                    Text("续播")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
            }
        }
    }

    private var formattedDuration: String {
        let totalMinutes = work.totalDurationMS / 60_000
        if totalMinutes >= 60 {
            return L10n.text("\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分")
        }
        return L10n.text("\(totalMinutes) 分")
    }
}
