import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private struct MediaPickerActionKey: EnvironmentKey {
    static let defaultValue: (MediaPickerRequest) -> Void = { _ in }
}

extension EnvironmentValues {
    var presentMediaPicker: (MediaPickerRequest) -> Void {
        get { self[MediaPickerActionKey.self] }
        set { self[MediaPickerActionKey.self] = newValue }
    }
}

/// Attach once to the editor's NavigationStack, outside its lazy Form rows.
/// Freeze the source, target and callback for one presentation. Playback updates
/// must not reconfigure the system browser or replace its scrolling controller.
private struct MediaPickerPresentation: ViewModifier {
    @ObservedObject var presenter: MediaPickerPresenter

    func body(content: Content) -> some View {
        content
            .environment(\.presentMediaPicker, presenter.present)
            .sheet(item: $presenter.request, onDismiss: presenter.didDismiss) { current in
                let picker = SystemMediaPicker(source: current.source) { selection in
                    presenter.finish(current, selection: selection)
                }
                Group {
                    switch current.source {
                    case .photos: picker.ignoresSafeArea()
                    case .file: picker
                    }
                }
                .interactiveDismissDisabled(false)
            }
    }
}

extension View {
    func mediaPickerPresentation(_ presenter: MediaPickerPresenter) -> some View {
        modifier(MediaPickerPresentation(presenter: presenter))
    }
}

struct SystemMediaPicker: UIViewControllerRepresentable {
    let source: MediaPickerRequest.Source
    let onFinish: (MediaPickerRequest.Selection?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIViewController {
        switch source {
        case .photos:
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 1
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = context.coordinator
            return picker
        case .file(let types):
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
            picker.allowsMultipleSelection = false
            picker.delegate = context.coordinator
            return picker
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // Intentionally leave the configuration, selection and scroll position
        // alone when the parent updates its playback/statistics state.
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        (controller as? PHPickerViewController)?.delegate = nil
        (controller as? UIDocumentPickerViewController)?.delegate = nil
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
        private var onFinish: ((MediaPickerRequest.Selection?) -> Void)?

        init(onFinish: @escaping (MediaPickerRequest.Selection?) -> Void) { self.onFinish = onFinish }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            finish(results.first.map { .photo(LibraryPhotoSelection(provider: $0.itemProvider)) })
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first.map { .file($0) })
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }

        func invalidate() { onFinish = nil }

        private func finish(_ selection: MediaPickerRequest.Selection?) {
            let callback = onFinish
            onFinish = nil
            callback?(selection)
        }
    }
}
