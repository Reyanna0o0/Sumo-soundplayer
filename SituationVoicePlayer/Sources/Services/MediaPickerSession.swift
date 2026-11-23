import Foundation
import Combine
import UniformTypeIdentifiers

/// Retains the selected provider after the system picker has been dismissed.
struct LibraryPhotoSelection {
    let provider: NSItemProvider

    func loadData() async throws -> Data {
        try Task.checkCancellation()
        let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CocoaError(.fileReadCorruptFile)) }
            }
        }
        try Task.checkCancellation()
        return data
    }
}

struct MediaPickerRequest: Identifiable {
    enum Source {
        case photos
        case file([UTType])
    }
    enum Selection {
        case photo(LibraryPhotoSelection)
        case file(URL)
    }

    let id = UUID()
    let source: Source
    let onSelection: (Selection) -> Void

    static func photo(_ onSelect: @escaping (LibraryPhotoSelection) -> Void) -> Self {
        Self(source: .photos) { if case .photo(let photo) = $0 { onSelect(photo) } }
    }

    static func file(types: [UTType], onSelect: @escaping (URL) -> Void) -> Self {
        Self(source: .file(types)) { if case .file(let url) = $0 { onSelect(url) } }
    }
}

@MainActor
final class MediaPickerPresenter: ObservableObject {
    @Published var request: MediaPickerRequest? {
        didSet {
            if oldValue != nil, request == nil { isFinishing = true }
        }
    }
    private var isFinishing = false
    private var pendingSelection: (() -> Void)?

    func present(_ next: MediaPickerRequest) {
        guard request == nil, !isFinishing else { return }
        request = next
    }

    func finish(_ current: MediaPickerRequest, selection: MediaPickerRequest.Selection?) {
        guard request?.id == current.id, !isFinishing else { return }
        if let selection { pendingSelection = { current.onSelection(selection) } }
        request = nil
    }

    func didDismiss() {
        let finish = pendingSelection
        pendingSelection = nil
        isFinishing = false
        // Import/crop only after dismissal has finished. Cancelling,
        // including a swipe dismissal, does not touch the editor draft.
        finish?()
    }
}
