import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The visible order is a draft while the finger is down. Only a validated
/// local drop writes preferences; cancellation restores the last saved order.
@MainActor
final class StatisticsArrangement: ObservableObject {
    enum Feedback: Equatable {
        case idle, dragging, saving, saved, cancelled, failed
        case visibility(StatisticsModule, Bool)
    }
    @Published private(set) var isEditing = false
    @Published private(set) var order: [StatisticsModule] = []
    @Published private(set) var dragged: StatisticsModule?
    @Published private(set) var feedback: Feedback = .idle
    private var baseline: [StatisticsModule] = []
    private var token: UUID?
    private var pendingDrop = false
    private var providerCount = 0
    private weak var dragPreferences: StatisticsPreferences?
    // A token plus ownProcess visibility prevents another app's text/file drop
    // from being accepted. No public import format is introduced for UI order.
    static let type = UTType.utf8PlainText

    var hint: String {
        switch feedback {
        case .saving: return L10n.text("正在保存顺序…")
        case .saved: return L10n.text("顺序已保存")
        case .cancelled: return L10n.text("本次拖动未保存")
        case .failed: return L10n.text("这次顺序未保存，请重新拖动")
        case .visibility(let module, let enabled):
            return L10n.text("\(module.displayName)已\(enabled ? L10n.text("显示") : L10n.text("隐藏"))，已即时保存")
        case .idle, .dragging: return L10n.text("松手保存顺序；隐藏和显示即时保存")
        }
    }

    func enter(_ preferences: StatisticsPreferences) {
        guard !isEditing else { return }
        order = preferences.moduleOrder
        baseline = order
        feedback = .idle
        isEditing = true
    }

    func finish(_ preferences: StatisticsPreferences) {
        cancelDrag(preferences)
        feedback = .idle
        isEditing = false
    }

    func synchronize(_ preferences: StatisticsPreferences) {
        if token != nil, baseline != preferences.moduleOrder { cancelDrag(preferences) }
        if token == nil { order = preferences.moduleOrder; baseline = order }
    }

    func begin(_ module: StatisticsModule, preferences: StatisticsPreferences) -> NSItemProvider {
        enter(preferences)
        if dragged != module || token == nil || pendingDrop {
            cancelDrag(preferences)
            dragged = module
            token = UUID()
            dragPreferences = preferences
            feedback = .dragging
        }
        guard let token else { return NSItemProvider() }
        let provider = StatisticsDragProvider()
        providerCount += 1
        provider.suggestedName = token.uuidString
        provider.didRelease = { [weak self] in
            Task { @MainActor in
                guard let self, self.token == token, let preferences = self.dragPreferences else { return }
                self.providerCount = max(0, self.providerCount - 1)
                if self.providerCount == 0 && !self.pendingDrop { self.cancelDrag(preferences) }
            }
        }
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(Data(token.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    func preview(over target: StatisticsModule, after: Bool) {
        guard !pendingDrop, let dragged, target != dragged,
              let from = order.firstIndex(of: dragged), order.contains(target) else { return }
        var updated = order
        updated.remove(at: from)
        guard let destination = updated.firstIndex(of: target) else { return }
        updated.insert(dragged, at: destination + (after ? 1 : 0))
        if updated != order { order = updated }
    }

    func cancelDrag(_ preferences: StatisticsPreferences) {
        token = nil; dragged = nil; pendingDrop = false; providerCount = 0
        dragPreferences = nil
        order = preferences.moduleOrder
        baseline = order
        if feedback == .dragging || feedback == .saving { feedback = .idle }
    }

    /// Also used by accessibility actions; there is no unfinished drag to save.
    func move(_ module: StatisticsModule, by offset: Int, preferences: StatisticsPreferences) {
        cancelDrag(preferences)
        feedback = .idle
        guard let from = order.firstIndex(of: module), order.indices.contains(from + offset) else { return }
        var updated = order
        updated.swapAt(from, from + offset)
        preferences.updateOrder(updated)
        synchronize(preferences)
        feedback = preferences.moduleOrder == updated ? .saved : .failed
    }

    func setVisible(_ enabled: Bool, module: StatisticsModule, preferences: StatisticsPreferences) {
        cancelDrag(preferences)
        feedback = .idle
        guard !preferences.isPinned(module), preferences.isEnabled(module) != enabled else { return }
        preferences.setEnabled(enabled, for: module)
        if preferences.isEnabled(module) == enabled { feedback = .visibility(module, enabled) }
    }

    func accepts(_ provider: NSItemProvider, preferences: StatisticsPreferences) -> Bool {
        isEditing && !pendingDrop && token != nil && provider.suggestedName == token?.uuidString
            && baseline == preferences.moduleOrder
    }

    @discardableResult
    func commit(_ data: Data, preferences: StatisticsPreferences) -> Bool {
        // A duplicate/late callback must not overwrite the last result.
        guard let token else { return false }
        guard String(data: data, encoding: .utf8) == token.uuidString,
              baseline == preferences.moduleOrder else {
            cancelDrag(preferences); feedback = .failed; return false
        }
        let proposed = order
        let changed = proposed != baseline
        preferences.updateOrder(proposed)
        let saved = preferences.moduleOrder == proposed
        cancelDrag(preferences)
        feedback = saved ? (changed ? .saved : .idle) : .failed
        return saved
    }

    /// Reserve before loading bytes so the system's visual drag end cannot
    /// cancel a local drop whose asynchronous transfer is still completing.
    func reserveDrop(from provider: NSItemProvider, preferences: StatisticsPreferences) -> Bool {
        guard accepts(provider, preferences: preferences),
              provider.hasItemConformingToTypeIdentifier(Self.type.identifier) else { return false }
        pendingDrop = true
        feedback = .saving
        return true
    }

    func systemDragEnded(token: String, operation: UIDropOperation) {
        guard self.token?.uuidString == token, !pendingDrop,
              let preferences = dragPreferences else { return }
        cancelDrag(preferences)
        if operation == .cancel || operation == .forbidden { feedback = .cancelled }
    }

    func drop(_ provider: NSItemProvider, preferences: StatisticsPreferences) -> Bool {
        guard let token, reserveDrop(from: provider, preferences: preferences) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: Self.type.identifier) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.token == token, let preferences = self.dragPreferences else { return }
                guard error == nil, let data else {
                    self.cancelDrag(preferences); self.feedback = .failed; return
                }
                _ = self.commit(data, preferences: preferences)
            }
        }
        return true
    }
}

private final class StatisticsDragProvider: NSItemProvider, @unchecked Sendable {
    var didRelease: (@Sendable () -> Void)?
    deinit { didRelease?() }
}

/// Keep real header actions tappable through the transparent drag source.
struct StatisticsArrangementActionBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

struct StatisticsModuleDropDelegate: DropDelegate {
    var module: StatisticsModule?
    var height: CGFloat = 1
    let arrangement: StatisticsArrangement
    let preferences: StatisticsPreferences

    private func provider(_ info: DropInfo) -> NSItemProvider? {
        let providers = info.itemProviders(for: [StatisticsArrangement.type])
        guard providers.count == 1, let provider = providers.first,
              arrangement.accepts(provider, preferences: preferences) else { return nil }
        return provider
    }
    func validateDrop(info: DropInfo) -> Bool { provider(info) != nil }
    func dropEntered(info: DropInfo) {
        guard provider(info) != nil else { return }
        preview(info)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard provider(info) != nil else { return DropProposal(operation: .forbidden) }
        preview(info)
        return DropProposal(operation: .move)
    }
    private func preview(_ info: DropInfo) {
        guard let module else { return } // Container fallback accepts gaps/end space.
        withAnimation(.easeInOut(duration: 0.2)) {
            arrangement.preview(over: module, after: info.location.y >= height / 2)
        }
    }
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = provider(info) else { return false }
        return arrangement.drop(provider, preferences: preferences)
    }
}

struct StatisticsArrangementGesture: ViewModifier {
    let module: StatisticsModule
    let height: CGFloat
    @ObservedObject var arrangement: StatisticsArrangement
    let preferences: StatisticsPreferences

    func body(content: Content) -> some View {
        if arrangement.isEditing {
            content
                .overlayPreferenceValue(StatisticsArrangementActionBounds.self) { anchors in
                    GeometryReader { geometry in
                        StatisticsArrangementDragSource(module: module, arrangement: arrangement,
                            preferences: preferences, excludedRects: anchors.map { geometry[$0] })
                    }
                }
                .onDrop(of: [StatisticsArrangement.type], delegate: StatisticsModuleDropDelegate(
                    module: module, height: height, arrangement: arrangement, preferences: preferences))
        } else {
            content.simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                arrangement.enter(preferences)
            })
        }
    }
}

/// SwiftUI supplies the existing drop targets; UIKit supplies a deterministic
/// source-session end even when the provider remains alive after cancellation.
private struct StatisticsArrangementDragSource: UIViewRepresentable {
    let module: StatisticsModule
    let arrangement: StatisticsArrangement
    let preferences: StatisticsPreferences
    let excludedRects: [CGRect]

    func makeCoordinator() -> Coordinator { Coordinator(source: self) }
    func makeUIView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        let drag = UIDragInteraction(delegate: context.coordinator)
        drag.isEnabled = true
        view.addInteraction(drag)
        return view
    }
    func updateUIView(_ view: DragSourceView, context: Context) {
        context.coordinator.source = self
        view.excludedRects = excludedRects.map {
            $0.insetBy(dx: -max(0, (44 - $0.width) / 2), dy: -max(0, (44 - $0.height) / 2))
        }
    }

    final class DragSourceView: UIView {
        var excludedRects: [CGRect] = []
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            !excludedRects.contains(where: { $0.contains(point) }) && super.point(inside: point, with: event)
        }
    }

    final class Coordinator: NSObject, UIDragInteractionDelegate {
        var source: StatisticsArrangementDragSource
        init(source: StatisticsArrangementDragSource) { self.source = source }

        private final class LocalSession {
            weak var arrangement: StatisticsArrangement?
            let token: String
            var preview: UIView?
            init(arrangement: StatisticsArrangement, token: String, preview: UIView?) {
                self.arrangement = arrangement; self.token = token; self.preview = preview
            }
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            guard source.arrangement.isEditing, let view = interaction.view, let window = view.window else { return [] }
            let frame = view.convert(view.bounds, to: window)
            let preview = window.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero)
            let provider = source.arrangement.begin(source.module, preferences: source.preferences)
            guard let token = provider.suggestedName,
                  provider.hasItemConformingToTypeIdentifier(StatisticsArrangement.type.identifier) else { return [] }
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
