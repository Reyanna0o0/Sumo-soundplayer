import SwiftUI
import UIKit

/// The temporary input outlives the picker, including a cancelled or retried crop.
final class CoverCropInput: Identifiable {
    let id = UUID()
    let relativePath: String
    init(relativePath: String) { self.relativePath = relativePath }
    deinit { WorkAssetImporter.remove(relativePath) }
}

struct CoverCropSheet: View {
    let input: CoverCropInput
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    // Fraction of the available travel. Zero selects the centre at every zoom level.
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @State private var errorMessage: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Color.clear.aspectRatio(4 / 3, contentMode: .fit)
                        .overlay {
                            if let image {
                                GeometryReader { frame in viewport(image, size: frame.size) }
                            } else if errorMessage == nil { ProgressView() }
                        }
                        .background(.black).clipped()
                        .accessibilityLabel("封面取景框").accessibilityIdentifier("cropViewport")
                    HStack {
                        Image(systemName: "minus.magnifyingglass")
                        Slider(value: $zoom, in: 1...5).accessibilityLabel("封面缩放")
                            .accessibilityIdentifier("cropZoom")
                        Image(systemName: "plus.magnifyingglass")
                    }
                    HStack {
                        Text("拖动图片调整位置，双指或滑块缩放。")
                            .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                        Spacer()
                        Button("复位") { zoom = 1; pan = .zero }
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                .frame(maxWidth: 600).padding().frame(maxWidth: .infinity)
            }
            .appPageBackground(AppTheme.painted(.clear, AppTheme.background))
            .tint(AppTheme.usesCustomPalette ? AppTheme.accent : nil)
            .appNavigationColors().navigationTitle(L10n.text("裁剪封面")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用", action: save).disabled(image == nil || saving)
                        .accessibilityIdentifier("useCrop")
                }
            }
            .disabled(saving).interactiveDismissDisabled(saving)
            .task {
                guard let path = WorkAssetImporter.path(for: input.relativePath),
                      let loaded = UIImage(contentsOfFile: path) else {
                    errorMessage = L10n.text("无法读取所选图片。"); return
                }
                image = loaded
            }
        }
    }

    private func viewport(_ image: UIImage, size: CGSize) -> some View {
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let currentZoom = min(5, max(1, zoom * pinch))
        let drawn = CGSize(width: image.size.width * scale * currentZoom,
                           height: image.size.height * scale * currentZoom)
        let limit = CGSize(width: max(0, (drawn.width - size.width) / 2),
                           height: max(0, (drawn.height - size.height) / 2))
        let offset = CGSize(width: min(limit.width, max(-limit.width, pan.width * limit.width + drag.width)),
                            height: min(limit.height, max(-limit.height, pan.height * limit.height + drag.height)))
        return Image(uiImage: image).resizable().frame(width: drawn.width, height: drawn.height)
            .position(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
            .frame(width: size.width, height: size.height).clipped().contentShape(Rectangle())
            .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    if limit.width > 0 { pan.width = min(1, max(-1, pan.width + value.translation.width / limit.width)) }
                    if limit.height > 0 { pan.height = min(1, max(-1, pan.height + value.translation.height / limit.height)) }
                })
            .simultaneousGesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                .onEnded { value in zoom = min(5, max(1, zoom * value)) })
    }

    private func save() {
        guard let image, !saving else { return }
        let ratio: CGFloat = 4 / 3
        let width = min(image.size.width, image.size.height * ratio) / zoom
        let height = width / ratio
        let rect = CGRect(x: (image.size.width - width) * (1 - pan.width) / 2,
                          y: (image.size.height - height) * (1 - pan.height) / 2,
                          width: width, height: height)
        saving = true
        let inputPath = input.relativePath
        Task {
            defer { saving = false }
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try WorkAssetImporter.croppedCover(from: inputPath, rect: rect)
                }.value
                onUse(file)
                dismiss()
            } catch { errorMessage = L10n.text("裁剪失败：\(error.localizedDescription)") }
        }
    }
}
