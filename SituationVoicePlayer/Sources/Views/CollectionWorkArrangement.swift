import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A drag changes this local draft only. The original visible subset remains the
/// optimistic-concurrency snapshot passed to LibraryStore on a successful drop.
struct CollectionWorkOrderDraft: Equatable {
    let originalIDs: [Int64]
    let sourceID: Int64
    private(set) var orderedIDs: [Int64]

    init?(sourceID: Int64, visibleIDs: [Int64]) {
        guard visibleIDs.contains(sourceID), Set(visibleIDs).count == visibleIDs.count else { return nil }
        originalIDs = visibleIDs
        self.sourceID = sourceID
        orderedIDs = visibleIDs
    }

    mutating func move(toSlot slot: Int) {
        guard orderedIDs.indices.contains(slot), let from = orderedIDs.firstIndex(of: sourceID), from != slot else { return }
        orderedIDs.remove(at: from)
        orderedIDs.insert(sourceID, at: slot)
    }

    /// Slots are actual grid cells, including horizontal neighbours. Looking up
    /// the nearest cell also covers the gutters and empty trailing grid area.
    static func slot(at point: CGPoint, frames: [Int: CGRect], count: Int) -> Int? {
        let valid = frames.filter { (0..<count).contains($0.key) && $0.value.width > 0 && $0.value.height > 0 }
        // Choose the row first: blank space after an incomplete final row must
        // resolve to its last card, not a geometrically closer card one row up.
        guard let row = valid.min(by: {
            let left = abs(point.y - $0.value.midY), right = abs(point.y - $1.value.midY)
            return left == right ? $0.key < $1.key : left < right
        }) else { return nil }
        return valid.filter { abs($0.value.minY - row.value.minY) < 1 }
            .min {
                let left = abs(point.x - $0.value.midX), right = abs(point.x - $1.value.midX)
                return left == right ? $0.key < $1.key : left < right
            }?.key
    }
}

@MainActor
final class CollectionWorkArrangement: ObservableObject {
    enum Feedback: Equatable { case idle, dragging, saving, saved, cancelled, failed }
    // Reuse the already declared local work-order UTI. A separate session token
    // prevents this handler from accepting a personal-library drag.
    static let type = MediaWorkDragSession.type
    static let coordinateSpace = "collectionArrangementGrid"
    private struct Transfer: Codable, Equatable {
        let token: UUID
        let sourceID: Int64
        let visibleIDs: [Int64]
    }
    @Published private(set) var isEditing = false
    @Published private(set) var draft: CollectionWorkOrderDraft?
    @Published private(set) var feedback: Feedback = .idle
    private var transfer: Transfer?
    private var pendingToken: UUID?
    private var providerCount = 0
    private var lastRejection: String?

    var hint: String {
        switch feedback {
        case .saving: return L10n.text("正在保存顺序…")
        case .saved: return L10n.text("顺序已保存")
        case .cancelled: return L10n.text("本次拖动未保存")
        case .failed: return L10n.text("这次顺序未保存，请重新拖动")
        case .idle, .dragging:
            return isEditing ? L10n.text("拖动作品调整位置，松手保存") : L10n.text("长按作品进入整理模式")
        }
    }

    func enter() {
        guard !isEditing else { return }
        feedback = .idle
        isEditing = true
    }
    func finish() { cancelDrag(); feedback = .idle; isEditing = false }

    func cancelDrag() {
        if transfer != nil { diagnose("clear current drag") }
        transfer = nil
        pendingToken = nil
        providerCount = 0
        lastRejection = nil
        draft = nil
        // This also runs after a successful drop or a view refresh. Only the
        // explicit system-cancellation path may announce an unsaved drag.
        if feedback == .dragging || feedback == .saving { feedback = .idle }
    }

    func displayedWorks(_ works: [WorkRecord]) -> [WorkRecord] {
        guard let draft, draft.originalIDs == works.map(\.id) else { return works }
        let byID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
        return draft.orderedIDs.compactMap { byID[$0] }
    }

    func begin(sourceID: Int64, visibleIDs: [Int64]) -> NSItemProvider {
        guard isEditing, let initial = CollectionWorkOrderDraft(sourceID: sourceID, visibleIDs: visibleIDs) else { return NSItemProvider() }
        let current: Transfer
        if let transfer, transfer.sourceID == sourceID, transfer.visibleIDs == visibleIDs, pendingToken == nil {
            current = transfer
        } else {
            cancelDrag()
            current = Transfer(token: UUID(), sourceID: sourceID, visibleIDs: visibleIDs)
            transfer = current
            draft = initial
            feedback = .dragging
            diagnose("begin source=\(sourceID) count=\(visibleIDs.count)")
        }
        guard let data = try? JSONEncoder().encode(current) else { cancelDrag(); return NSItemProvider() }
        let provider = CollectionArrangementProvider()
        providerCount += 1
        provider.suggestedName = current.token.uuidString
        provider.didRelease = { [weak self] in
            Task { @MainActor in
                guard let self, self.transfer?.token == current.token else { return }
                self.providerCount = max(0, self.providerCount - 1)
                if self.providerCount == 0 && self.pendingToken == nil { self.cancelDrag() }
            }
        }
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    fileprivate func accepts(_ info: DropInfo, visibleIDs: [Int64], store: LibraryStore) -> Bool {
        let correctLibrary = store.currentLibrary == .collection && store.sortOrder == .custom
        let sameSnapshot = transfer?.visibleIDs == visibleIDs
        let localProvider = provider(in: info) != nil
        let accepted = isEditing && pendingToken == nil && correctLibrary && sameSnapshot && localProvider
        if accepted { lastRejection = nil }
        else {
            let reason = "reject editing=\(isEditing) pending=\(pendingToken != nil) library=\(correctLibrary) snapshot=\(sameSnapshot) provider=\(localProvider)"
            if reason != lastRejection { diagnose(reason); lastRejection = reason }
        }
        return accepted
    }

    fileprivate func hover(at point: CGPoint, frames: [Int: CGRect]) {
        guard let draft,
              let slot = CollectionWorkOrderDraft.slot(at: point, frames: frames, count: draft.originalIDs.count) else { return }
        hover(slot: slot)
    }

    func hover(slot: Int) {
        guard pendingToken == nil, var next = draft else { return }
        next.move(toSlot: slot)
        if next != draft {
            diagnose("preview slot=\(slot) order=\(next.orderedIDs)")
            withAnimation(.easeInOut(duration: 0.18)) { draft = next }
        }
    }

    fileprivate func entered(slot: Int?, point: CGPoint, frameCount: Int) {
        diagnose("enter target=\(slot.map(String.init) ?? "container") point=\(point) frames=\(frameCount)")
    }

    fileprivate func diagnose(_ message: String) {
        #if DEBUG
        if Bundle.main.bundleIdentifier == "io.github.gloriaguuuu.simo.call1111sim",
           CommandLine.arguments.contains("-collectionArrangementDiagnostics") {
            print("COLLECTION_ARRANGEMENT \(message)")
        }
        #endif
    }

    /// Reserve synchronously before asking the provider for bytes. UIKit may
    /// finish its visual drag before that asynchronous data transfer completes.
    func reserveDrop(from provider: NSItemProvider) -> Bool {
        guard isEditing, let transfer, draft != nil, pendingToken == nil,
              provider.suggestedName == transfer.token.uuidString,
              provider.hasItemConformingToTypeIdentifier(Self.type.identifier) else { return false }
        pendingToken = transfer.token
        feedback = .saving
        return true
    }

    /// UIKit supplies a deterministic lifecycle end; an item provider can stay
    /// alive after cancellation and therefore is only a cleanup fallback.
    func systemDragEnded(token: String, operation: UIDropOperation) {
        guard transfer?.token.uuidString == token else { return }
        diagnose("system end operation=\(operation.rawValue) pending=\(pendingToken != nil)")
        guard pendingToken == nil else { return }
        cancelDrag()
        if operation == .cancel || operation == .forbidden { feedback = .cancelled }
    }

    fileprivate func drop(_ info: DropInfo, store: LibraryStore) -> Bool {
        guard let provider = provider(in: info) else { return false }
        return drop(provider, store: store)
    }

    func drop(_ provider: NSItemProvider, store: LibraryStore) -> Bool {
        guard let transfer, let draft, reserveDrop(from: provider) else { return false }
        diagnose("drop order=\(draft.orderedIDs)")
        provider.loadDataRepresentation(forTypeIdentifier: Self.type.identifier) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.pendingToken == transfer.token, self.transfer == transfer, self.isEditing else { return }
                defer { self.cancelDrag() }
                guard error == nil, let data,
                      (try? JSONDecoder().decode(Transfer.self, from: data)) == transfer else {
                    self.feedback = .failed
                    store.reportError(L10n.text("没有读取到这次拖动，请重新拖动作品。"))
                    return
                }
                guard draft.orderedIDs != draft.originalIDs else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    let saved = store.reorderWorks(draft.orderedIDs, visibleIDs: draft.originalIDs, library: .collection)
                    self.feedback = saved ? .saved : .failed
                    if !saved { store.reportError(L10n.text("这次顺序没有保存，请重新拖动作品。")) }
                    self.diagnose("commit saved=\(saved)")
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

private final class CollectionArrangementProvider: NSItemProvider, @unchecked Sendable {
    var didRelease: (@Sendable () -> Void)?
    deinit { didRelease?() }
}

struct CollectionGridFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct CollectionGridDropDelegate: DropDelegate {
    let session: CollectionWorkArrangement
    let store: LibraryStore
    let visibleIDs: [Int64]
    var frames: [Int: CGRect] = [:]
    var slot: Int? = nil

    func validateDrop(info: DropInfo) -> Bool { session.accepts(info, visibleIDs: visibleIDs, store: store) }
    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { session.entered(slot: slot, point: info.location, frameCount: frames.count) }
        update(info)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let valid = validateDrop(info: info)
        // Once a card yields its slot, its view is moving out from under the
        // pointer. Re-reading that card's new index on every animation frame
        // would move the source back. New card entry chooses the next slot;
        // only the stationary container keeps tracking its geometric gaps.
        if valid && slot == nil { update(info) }
        return DropProposal(operation: valid ? .move : .forbidden)
    }
    // Moving between a child card and its parent container can produce exits in
    // either order. Never discard the draft on that handoff. A cancelled system
    // drag releases its provider; leaving the page/background also clears it.
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        if slot == nil { update(info) }
        return session.drop(info, store: store)
    }
    private func update(_ info: DropInfo) {
        guard validateDrop(info: info) else { return }
        if let slot { session.hover(slot: slot) }
        else { session.hover(at: info.location, frames: frames) }
    }
}

struct CollectionCardArrangement: ViewModifier {
    let workID: Int64
    let visibleIDs: [Int64]
    let isCustom: Bool
    @ObservedObject var session: CollectionWorkArrangement

    @ViewBuilder func body(content: Content) -> some View {
        if isCustom && session.isEditing {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(AppTheme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .opacity(session.draft?.sourceID == workID ? 0.35 : 1)
                .overlay {
                    CollectionArrangementDragSource(workID: workID, visibleIDs: visibleIDs, arrangement: session)
                }
                .accessibilityHint("整理模式，拖动调整作品位置")
        } else if isCustom {
            content.highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in session.enter() })
                .accessibilityAction(named: L10n.text("整理作品")) { session.enter() }
        } else {
            content
        }
    }
}

/// Only the source interaction needs UIKit: SwiftUI's onDrag has no reliable
/// cancellation callback. Existing SwiftUI card/container drop targets remain.
private struct CollectionArrangementDragSource: UIViewRepresentable {
    let workID: Int64
    let visibleIDs: [Int64]
    let arrangement: CollectionWorkArrangement

    func makeCoordinator() -> Coordinator { Coordinator(source: self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        let drag = UIDragInteraction(delegate: context.coordinator)
        drag.isEnabled = true
        view.addInteraction(drag)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.source = self }

    final class Coordinator: NSObject, UIDragInteractionDelegate {
        var source: CollectionArrangementDragSource
        init(source: CollectionArrangementDragSource) { self.source = source }

        private final class LocalSession {
            weak var arrangement: CollectionWorkArrangement?
            let token: String
            var preview: UIView?
            init(arrangement: CollectionWorkArrangement, token: String, preview: UIView?) {
                self.arrangement = arrangement; self.token = token; self.preview = preview
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            guard source.arrangement.isEditing, let view = interaction.view, let window = view.window else { return [] }
            // Capture the actual card before begin() dims its source placeholder.
            // Snapshot only this card's rectangle, never the full screen image.
            let frame = view.convert(view.bounds, to: window)
            let preview = window.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero)
            let provider = source.arrangement.begin(sourceID: source.workID, visibleIDs: source.visibleIDs)
            guard let token = provider.suggestedName,
                  provider.hasItemConformingToTypeIdentifier(CollectionWorkArrangement.type.identifier) else { return [] }
            let context = LocalSession(arrangement: source.arrangement, token: token, preview: preview)
            session.localContext = context
            let item = UIDragItem(itemProvider: provider)
            item.previewProvider = { [weak context] in
                guard let preview = context?.preview else { return nil }
                return UIDragPreview(view: preview)
            }
            return [item]
        }

        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                             session: UIDragSession) -> UITargetedDragPreview? {
            guard let context = session.localContext as? LocalSession, let preview = context.preview,
                  let view = interaction.view, let window = view.window else { return nil }
            let frame = view.convert(view.bounds, to: window)
            let target = UIDragPreviewTarget(container: window, center: CGPoint(x: frame.midX, y: frame.midY))
            return UITargetedDragPreview(view: preview, parameters: UIDragPreviewParameters(), target: target)
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
        func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool { true }

        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, willEndWith operation: UIDropOperation) {
            if operation == .cancel || operation == .forbidden,
               let context = session.localContext as? LocalSession {
                context.arrangement?.systemDragEnded(token: context.token, operation: operation)
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
            guard let context = session.localContext as? LocalSession else { return }
            context.arrangement?.systemDragEnded(token: context.token, operation: operation)
            context.preview = nil
        }
    }
}
