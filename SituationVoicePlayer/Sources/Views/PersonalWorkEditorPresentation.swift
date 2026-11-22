import SwiftUI

enum PersonalWorkEditor: String {
    case metadata, relink, script, favorite
}

extension EnvironmentValues {
    @Entry var presentPersonalWorkEditor: (WorkRecord, PersonalWorkEditor) -> Void = { _, _ in }
}

/// A lazy card may leave the viewport while its keyboard is opening. Keep the
/// presentation and selected work on its containing page, not on the card.
private struct PersonalWorkEditorPresentation: ViewModifier {
    @ObservedObject var store: LibraryStore
    private struct Selection: Identifiable {
        let id = UUID()
        let work: WorkRecord
        let editor: PersonalWorkEditor
    }
    @State private var selection: Selection?

    func body(content: Content) -> some View {
        content
            .environment(\.presentPersonalWorkEditor) { work, editor in
                selection = Selection(work: work, editor: editor)
            }
            .porcelainSheet(item: $selection) { selection in
                let work = store.works.first { $0.id == selection.work.id }
                    ?? store.favoriteWorks.first { $0.id == selection.work.id }
                    ?? selection.work
                switch selection.editor {
                case .metadata: WorkMetadataEditorSheet(work: work, store: store)
                case .relink: PersonalAudioRelinkSheet(work: work, store: store)
                case .script: WorkScriptImportSheet(work: work, store: store)
                case .favorite: WorkFavoritePicker(workID: work.id)
                }
            }
    }
}

extension View {
    func personalWorkEditorPresentation(store: LibraryStore) -> some View {
        modifier(PersonalWorkEditorPresentation(store: store))
    }
}
