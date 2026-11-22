import SwiftUI
import UniformTypeIdentifiers

/// 两个整理入口共用一份拖动会话。预览只算位置，松手并核对载荷后才写一次。
@MainActor
final class WorkMediaDragSession: ObservableObject {
    static let type = UTType(exportedAs: "io.github.gloriaguuuu.simo.track-order", conformingTo: .data)

    private struct Transfer: Codable, Equatable {
        let token: UUID
        let payload: WorkReorderPayload
    }
    private var transfer: Transfer?
    private var snapshot: WorkReorderSnapshot?
    private var pendingToken: UUID?
    private var hoveredSurface: WorkDropSurface?
    @Published private(set) var destination: WorkDropDestination?

    func begin(_ payload: WorkReorderPayload, snapshot: WorkReorderSnapshot) -> NSItemProvider {
        // 悬停重绘可能再次求提供者：同一载荷的身份必须保持稳定。
        // 每次请求仍创建新的系统对象，取消过的对象不跨手势重复使用。
        let transfer: Transfer
        if let current = self.transfer, current.payload == payload, self.snapshot == snapshot {
            trace("reuse transfer identity")
            transfer = current
        } else {
            invalidate()
            transfer = Transfer(token: UUID(), payload: payload)
            self.transfer = transfer
            self.snapshot = snapshot
            trace("begin work=\(payload.workID) content=\(payload.content)")
        }
        guard let data = try? JSONEncoder().encode(transfer) else { return NSItemProvider() }
        let provider = NSItemProvider()
        provider.suggestedName = transfer.token.uuidString
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    func invalidate() {
        if transfer != nil { trace("invalidate") }
        transfer = nil; snapshot = nil; pendingToken = nil; destination = nil; hoveredSurface = nil
    }

    fileprivate func candidate(_ info: DropInfo, surface: WorkDropSurface, height: CGFloat) -> WorkDropDestination? {
        guard pendingToken == nil else { return nil }
        guard let transfer, let snapshot, matchingProvider(info) != nil else {
            trace("candidate unavailable active=\(transfer != nil) surface=\(surface)")
            return nil
        }
        let target = surface.destination(for: transfer.payload.content, after: info.location.y >= height / 2)
        guard (try? WorkReorderPlanner.plan(payload: transfer.payload, to: target, in: snapshot)) != nil else {
            trace("invalid plan \(target)"); return nil
        }
        trace("candidate \(target) y=\(info.location.y) height=\(height)")
        return target
    }

    private func matchingProvider(_ info: DropInfo) -> NSItemProvider? {
        let providers = info.itemProviders(for: [Self.type])
        trace("providers=\(providers.count) names=\(providers.map { $0.suggestedName != nil }) match=\(providers.first?.suggestedName == transfer?.token.uuidString)")
        guard providers.count == 1, let provider = providers.first,
              let transfer, provider.suggestedName == transfer.token.uuidString else { return nil }
        return provider
    }

    fileprivate func hover(_ target: WorkDropDestination?, surface: WorkDropSurface) {
        hoveredSurface = surface
        if let target, let transfer, let snapshot,
           let plan = try? WorkReorderPlanner.plan(payload: transfer.payload, to: target, in: snapshot),
           case .unchanged = plan {
            if destination != nil { destination = nil }
        } else if destination != target { destination = target }
    }

    fileprivate func leave(_ surface: WorkDropSurface) {
        // 旧行的退出回调可能晚于新行进入；只能清除仍属于自己的提示。
        if hoveredSurface == surface { destination = nil; hoveredSurface = nil }
    }

    fileprivate func drop(_ info: DropInfo, surface: WorkDropSurface, height: CGFloat,
                          save: @escaping (WorkReorderPayload, WorkDropDestination, WorkReorderSnapshot) throws -> Void,
                          onError: @escaping (String) -> Void) -> Bool {
        guard let target = candidate(info, surface: surface, height: height),
              let provider = matchingProvider(info), let transfer, let snapshot else { return false }
        // 捕获本次明确落点，异步读取载荷不能改用后来悬停的行。
        destination = nil
        pendingToken = transfer.token
        trace("perform \(target)")
        provider.loadDataRepresentation(forTypeIdentifier: Self.type.identifier) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.pendingToken == transfer.token,
                      self.transfer == transfer else { return }
                self.invalidate()
                guard error == nil, let data,
                      (try? JSONDecoder().decode(Transfer.self, from: data)) == transfer else {
                    onError(L10n.text("没有读取到这次拖动，请重新拖动。"))
                    return
                }
                do { try save(transfer.payload, target, snapshot) }
                catch { onError(error.localizedDescription) }
            }
        }
        return true
    }

    private func trace(_ message: String) {
        #if DEBUG
        if CommandLine.arguments.contains("-reorderTrace") { DebugLog.write("reorder \(message)") }
        #endif
    }
}

enum WorkDropSurface: Equatable {
    case header(String)
    case item(String, WorkMediaID)
    case footer(String)

    fileprivate func destination(for content: WorkReorderPayload.Content, after: Bool) -> WorkDropDestination {
        switch (self, content) {
        case (.header(let key), .group): return .groupEdge(category: key, after: after)
        case (.header(let key), .item): return .groupStart(key)
        case (.item(let key, _), .group): return .groupEdge(category: key, after: true)
        case (.item(let key, let item), .item): return .item(category: key, neighbor: item, after: after)
        case (.footer(let key), .group): return .groupEdge(category: key, after: true)
        case (.footer(let key), .item): return .groupEnd(key)
        }
    }

    fileprivate var edgeKey: String? {
        switch self {
        case .header(let key): return "before:" + key
        case .footer(let key): return "after:" + key
        case .item: return nil
        }
    }

    fileprivate func lineAlignment(for destination: WorkDropDestination?) -> Alignment? {
        guard let destination else { return nil }
        switch (self, destination) {
        case (.header(let key), .groupStart(let target)) where key == target: return .bottom
        case (.header(let key), .groupEdge(let target, false)) where key == target: return .top
        case (.item(let key, let item), .item(let target, let neighbor, let after)) where key == target && item == neighbor:
            return after ? .bottom : .top
        case (.footer(let key), .groupEnd(let target)) where key == target: return .center
        case (.footer(let key), .groupEdge(let target, true)) where key == target: return .center
        default: return nil
        }
    }
}

/// 分隔线属于投放区域本身，不再在两行之间留下接不到拖动的细缝。
struct WorkMediaDropZone<Content: View>: View {
    @ObservedObject var session: WorkMediaDragSession
    let surface: WorkDropSurface
    let save: (WorkReorderPayload, WorkDropDestination, WorkReorderSnapshot) throws -> Void
    let onError: (String) -> Void
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 44

    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = max(1, $0) }
            .overlay(alignment: surface.lineAlignment(for: session.destination) ?? .center) {
                if surface.lineAlignment(for: session.destination) != nil {
                    HStack(spacing: 0) {
                        Circle().frame(width: 6, height: 6)
                        Rectangle().frame(height: 2)
                    }
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .anchorPreference(key: WorkDropEdgeBounds.self, value: .bounds) { anchor in
                surface.edgeKey.map { [$0: anchor] } ?? [:]
            }
            .onDrop(of: [WorkMediaDragSession.type], delegate: WorkMediaDropDelegate(
                session: session, surface: surface, height: height, save: save, onError: onError))
    }
}

private struct WorkMediaDropDelegate: DropDelegate {
    let session: WorkMediaDragSession
    let surface: WorkDropSurface
    let height: CGFloat
    let save: (WorkReorderPayload, WorkDropDestination, WorkReorderSnapshot) throws -> Void
    let onError: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        session.candidate(info, surface: surface, height: height) != nil
    }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: session.candidate(info, surface: surface, height: height) == nil ? .forbidden : .move)
    }
    func dropExited(info: DropInfo) { session.leave(surface) }
    func performDrop(info: DropInfo) -> Bool {
        session.drop(info, surface: surface, height: height, save: save, onError: onError)
    }
    private func update(_ info: DropInfo) {
        session.hover(session.candidate(info, surface: surface, height: height), surface: surface)
    }
}


private struct WorkDropEdgeBounds: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// 整组落点在屏外时，在阅读视窗边缘标明目标；真正组尾进入屏幕后交还原插入线。
struct WorkGroupDropHint: ViewModifier {
    @ObservedObject var session: WorkMediaDragSession
    let sections: [WorkMediaSection]

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(WorkDropEdgeBounds.self) { anchors in
            GeometryReader { viewport in
                if case .groupEdge(let category, let after) = session.destination,
                   let section = sections.first(where: { $0.id == category }) {
                    let edge = anchors[(after ? "after:" : "before:") + category].map {
                        after ? viewport[$0].midY : viewport[$0].minY
                    }
                    if edge == nil || edge! < 8 || edge! > viewport.size.height - 8 {
                        VStack(spacing: 4) {
                            if after { label(section.category.localizedTitle, after: true) }
                            Rectangle().fill(AppTheme.accent).frame(height: 2)
                            if !after { label(section.category.localizedTitle, after: false) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(.regularMaterial)
                        .frame(maxHeight: .infinity, alignment: after ? .bottom : .top)
                        .accessibilityIdentifier("offscreenGroupDropHint")
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func label(_ title: String, after: Bool) -> some View {
        Label(after ? L10n.text("移到「\(title)」之后") : L10n.text("移到「\(title)」之前"), systemImage: after ? "arrow.down" : "arrow.up")
            .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
            .frame(maxWidth: .infinity)
    }
}
