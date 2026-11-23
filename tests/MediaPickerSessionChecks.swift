import Foundation
import UniformTypeIdentifiers

@main
struct MediaPickerSessionChecks {
    @MainActor static func main() async throws {
        var passed = 0
        let url = URL(fileURLWithPath: "/tmp/selected-image.png")

        do {
            let presenter = MediaPickerPresenter()
            var draft = "original"
            let request = MediaPickerRequest.file(types: [.image]) { _ in draft = "changed" }
            presenter.present(request)
            presenter.finish(request, selection: nil)
            presenter.didDismiss()
            precondition(draft == "original" && presenter.request == nil)
            passed += 1 // Explicit cancellation leaves the draft untouched.
        }

        do {
            let presenter = MediaPickerPresenter()
            var selections: [URL] = []
            let request = MediaPickerRequest.file(types: [.image]) { selections.append($0) }
            presenter.present(request)
            presenter.finish(request, selection: .file(url))
            precondition(selections.isEmpty && presenter.request == nil)
            presenter.finish(request, selection: .file(url))
            presenter.didDismiss()
            presenter.didDismiss()
            precondition(selections == [url])
            passed += 1 // Import runs once, only after dismissal (including crop chaining).
        }

        do {
            let presenter = MediaPickerPresenter()
            var targets: [String] = []
            let first = MediaPickerRequest.file(types: [.image]) { _ in targets.append("avatar") }
            let second = MediaPickerRequest.file(types: [.movie]) { _ in targets.append("background") }
            presenter.present(first)
            presenter.present(second)
            precondition(presenter.request?.id == first.id)
            presenter.finish(first, selection: .file(url))
            presenter.present(second)
            precondition(presenter.request == nil)
            presenter.didDismiss()
            precondition(targets == ["avatar"])
            presenter.present(second)
            presenter.finish(first, selection: .file(url))
            precondition(presenter.request?.id == second.id)
            presenter.finish(second, selection: .file(url))
            presenter.didDismiss()
            precondition(targets == ["avatar", "background"])
            passed += 1 // Double taps/delayed old callbacks cannot change the target.
        }

        do {
            let presenter = MediaPickerPresenter()
            var count = 0
            let request = MediaPickerRequest.file(types: [.image]) { _ in count += 1 }
            presenter.present(request)
            presenter.request = nil // SwiftUI's interactive dismissal writes the binding.
            presenter.finish(request, selection: .file(url))
            presenter.present(request)
            precondition(presenter.request == nil)
            presenter.didDismiss()
            precondition(count == 0)
            presenter.present(request)
            precondition(presenter.request?.id == request.id)
            presenter.finish(request, selection: nil)
            presenter.didDismiss()
            passed += 1
        }

        do {
            let presenter = MediaPickerPresenter()
            var count = 0
            for index in 0..<100 {
                let request = MediaPickerRequest.file(types: [.image]) { _ in count += 1 }
                presenter.present(request)
                precondition(presenter.request?.id == request.id)
                presenter.finish(request, selection: index.isMultiple(of: 2) ? .file(url) : nil)
                presenter.didDismiss()
            }
            precondition(count == 50)
            passed += 1 // Repeated select/cancel/reopen cycles do not leave a stuck session.
        }

        do {
            let presenter = MediaPickerPresenter()
            var chained = false
            let next = MediaPickerRequest.photo { _ in }
            let request = MediaPickerRequest.file(types: [.image]) { _ in
                presenter.present(next)
                chained = presenter.request?.id == next.id
            }
            presenter.present(request)
            presenter.finish(request, selection: .file(url))
            presenter.didDismiss()
            precondition(chained)
            presenter.finish(next, selection: nil)
            presenter.didDismiss()
            passed += 1 // The callback may safely present the next step.
        }

        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        // Generic image data avoids relying on the host LaunchServices type database.
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.image.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        let photo = LibraryPhotoSelection(provider: provider)
        let loaded = try await photo.loadData()
        precondition(loaded == data)
        passed += 1 // A selected provider remains readable after picker dismissal.

        do {
            let failedProvider = NSItemProvider()
            failedProvider.registerDataRepresentation(forTypeIdentifier: UTType.image.identifier, visibility: .all) { completion in
                completion(nil, CocoaError(.fileReadNoPermission))
                return nil
            }
            do {
                _ = try await LibraryPhotoSelection(provider: failedProvider).loadData()
                preconditionFailure("Provider failure must reach the editor's error handling")
            } catch { passed += 1 }
        }

        do {
            let cancelled = Task { @MainActor in try await photo.loadData() }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                preconditionFailure("Cancelled image import must not return usable data")
            } catch is CancellationError { passed += 1 }
        }

        print("Media picker session checks: \(passed) passed, 0 failed")
    }
}
