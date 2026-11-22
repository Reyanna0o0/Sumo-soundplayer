import SwiftUI

/// Reuse the existing file, subtitle and editing flows while showing a personal
/// work as one flat set of content instead of collection category groups.
struct PersonalWorkInfoView: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore

    var body: some View {
        WorkDetailView(work: work, store: store, presentation: .personal)
    }
}
