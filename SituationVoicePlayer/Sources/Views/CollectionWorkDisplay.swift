import SwiftUI

enum CollectionWorkDisplay: String {
    case covers, list
    static let preferenceKey = "library.collectionWorkDisplay"
    static func resolved(_ storedValue: String) -> Self { Self(rawValue: storedValue) ?? .covers }
    var toggled: Self { self == .covers ? .list : .covers }
}

/// Match the existing favorites row: cover on the left, title and attribution
/// on the right. The containing library owns selection and arrangement gestures.
struct CollectionWorkListRow: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(path: work.resolvedCoverPath ?? work.coverPath)
                .frame(width: 80, height: 60)
                .overlay(alignment: .topTrailing) {
                    WorkFileLinkBadge(work: work, store: store).padding(4)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(work.title).lineLimit(2).foregroundStyle(AppTheme.primaryText)
                if !work.subtitle.isEmpty {
                    Text(work.subtitle).font(.caption).foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold)).foregroundStyle(AppTheme.tertiaryText)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.separator).frame(height: 0.5).padding(.leading, 92)
        }
        .contentShape(Rectangle())
    }
}
