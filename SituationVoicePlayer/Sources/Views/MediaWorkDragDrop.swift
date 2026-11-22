import SwiftUI
import UniformTypeIdentifiers

/// Library-card ordering is a same-process, one-commit operation. Hovering only
/// shows an insertion edge; cancellation never changes the saved library order.
@MainActor
final class MediaWorkDragSession: ObservableObject {
    static let type = UTType(exportedAs: "io.github.gloriaguuuu.simo.work-order", conformingTo: .data)
    struct Destination: Equatable { let workID: Int64; let after: Bool }
    private struct Transfer: Codable, Equatable {
        let token: UUID
        let workID: Int64
        let library: MediaLibraryKind
        let visibleIDs: [Int64]
    }
    private var transfer: Transfer?
    private var pendingToken: UUID?
    private var providerCount = 0
    @Published private(set) var destination: Destination?

    func begin(workID: Int64, library: MediaLibraryKind, visibleIDs: [Int64]) -> NSItemProvider {
        guard visibleIDs.contains(workID), Set(visibleIDs).count == visibleIDs.count else { return NSItemProvider() }
        let transfer: Transfer
        if let current = self.transfer, current.workID == workID,
           current.library == library, current.visibleIDs == visibleIDs, pendingToken == nil {
            // SwiftUI can ask again as the hover marker redraws. Keep the same
            // transfer identity while returning a fresh system provider object.
            transfer = current
        } else {
            invalidate()
            transfer = Transfer(token: UUID(), workID: workID, library: library, visibleIDs: visibleIDs)
            self.transfer = transfer
        }
        guard let data = try? JSONEncoder().encode(transfer) else { invalidate(); return NSItemProvider() }
        let provider = MediaWorkDragProvider()
        providerCount += 1
        provider.suggestedName = transfer.token.uuidString
        provider.didRelease = { [weak self] in
            Task { @MainActor in
                guard let self, self.transfer?.token == transfer.token else { return }
                self.providerCount = max(0, self.providerCount - 1)
                if self.providerCount == 0 && self.pendingToken == nil { self.invalidate() }
            }
        }
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    func invalidate() {
        transfer = nil
        pendingToken = nil
        providerCount = 0
        destination = nil
    }

    fileprivate func candidate(_ info: DropInfo, target: Int64, height: CGFloat,
                               visibleIDs: [Int64], library: MediaLibraryKind) -> Destination? {
        guard pendingToken == nil, let transfer, transfer.library == library,
              transfer.visibleIDs == visibleIDs, visibleIDs.contains(target), target != transfer.workID,
              provider(in: info) != nil else { return nil }
        return Destination(workID: target, after: info.location.y >= height / 2)
    }

    fileprivate func hover(_ target: Destination?) { if destination != target { destination = target } }

    fileprivate func leave(_ target: Int64) {
        // A delayed exit from the old card cannot clear the new card's marker.
        if destination?.workID == target { destination = nil }
    }

    fileprivate func drop(_ info: DropInfo, destination: Destination, store: LibraryStore) -> Bool {
        guard let provider = provider(in: info), let transfer, pendingToken == nil else { return false }
        pendingToken = transfer.token
        self.destination = nil
        provider.loadDataRepresentation(forTypeIdentifier: Self.type.identifier) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.pendingToken == transfer.token, self.transfer == transfer else { return }
                self.invalidate()
                guard error == nil, let data,
                      (try? JSONDecoder().decode(Transfer.self, from: data)) == transfer else {
                    store.reportError(L10n.text("没有读取到这次拖动，请重新拖动作品。"))
                    return
                }
                withAnimation(.easeInOut(duration: 0.18)) {
                    _ = store.moveWork(transfer.workID, relativeTo: destination.workID, after: destination.after,
                                       visibleIDs: transfer.visibleIDs, library: transfer.library)
                }
            }
        }
        return true
    }

    private func provider(in info: DropInfo) -> NSItemProvider? {
        let providers = info.itemProviders(for: [Self.type])
        guard let transfer, providers.count == 1, let provider = providers.first,
              provider.suggestedName == transfer.token.uuidString else { return nil }
        return provider
    }
}

/// SwiftUI onDrag has no cancellation callback. The provider's release clears a
/// cancelled local session; dropExited and view lifecycle also clear its marker.
private final class MediaWorkDragProvider: NSItemProvider, @unchecked Sendable {
    var didRelease: (@Sendable () -> Void)?
    deinit { didRelease?() }
}

struct MediaWorkReordering: ViewModifier {
    let work: WorkRecord
    let visibleIDs: [Int64]
    @ObservedObject var store: LibraryStore
    @ObservedObject var session: MediaWorkDragSession
    @State private var height: CGFloat = 1

    func body(content: Content) -> some View {
        if store.sortOrder == .custom {
            content
                .contentShape(Rectangle())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = max(1, $0) }
                .overlay(alignment: session.destination?.after == true ? .bottom : .top) {
                    if session.destination?.workID == work.id {
                        Rectangle().fill(AppTheme.accent).frame(height: 3)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .onDrag { session.begin(workID: work.id, library: work.libraryKind, visibleIDs: visibleIDs) }
                .onDrop(of: [MediaWorkDragSession.type], delegate: MediaWorkDropDelegate(
                    work: work, visibleIDs: visibleIDs, height: height, store: store, session: session))
        } else { content }
    }
}

private struct MediaWorkDropDelegate: DropDelegate {
    let work: WorkRecord
    let visibleIDs: [Int64]
    let height: CGFloat
    let store: LibraryStore
    let session: MediaWorkDragSession

    private func destination(_ info: DropInfo) -> MediaWorkDragSession.Destination? {
        guard store.sortOrder == .custom, store.currentLibrary == work.libraryKind else { return nil }
        return session.candidate(info, target: work.id, height: height, visibleIDs: visibleIDs, library: work.libraryKind)
    }
    func validateDrop(info: DropInfo) -> Bool { destination(info) != nil }
    func dropEntered(info: DropInfo) { session.hover(destination(info)) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = destination(info)
        session.hover(target)
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }
    func dropExited(info: DropInfo) { session.leave(work.id) }
    func performDrop(info: DropInfo) -> Bool {
        guard let target = destination(info) else { return false }
        return session.drop(info, destination: target, store: store)
    }
}

@MainActor
func mediaWorkMoveAction(work: WorkRecord, offset: Int, visibleIDs: [Int64],
                         store: LibraryStore, session: MediaWorkDragSession) -> (() -> Void)? {
    guard store.sortOrder == .custom, let index = visibleIDs.firstIndex(of: work.id),
          visibleIDs.indices.contains(index + offset) else { return nil }
    let target = visibleIDs[index + offset]
    return {
        session.invalidate()
        withAnimation(.easeInOut(duration: 0.18)) {
            _ = store.moveWork(work.id, relativeTo: target, after: offset > 0,
                               visibleIDs: visibleIDs, library: work.libraryKind)
        }
    }
}

struct MediaWorkOrderingHint: View {
    var body: some View {
        Label("长按作品卡片拖动排序", systemImage: "hand.draw")
            .font(.caption).foregroundStyle(AppTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("mediaWorkOrderingHint")
    }
}
