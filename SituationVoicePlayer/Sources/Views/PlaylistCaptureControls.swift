import SwiftUI

/// 在听的当下记下起止时间，写文件期间可继续播放。
struct PlaylistCaptureControls: View {
    let savedToken: UUID
    let onClipRequest: (SubtitleClipDraft) -> Void
    @EnvironmentObject private var player: PlayerController
    @State private var status: String?
    var body: some View {
        if let item = player.currentItem, !item.isSavedClip {
            VStack(spacing: 4) {
                HStack(spacing: 12) {
                    if let start = player.clipStartMS {
                        Button {
                            let end = player.capturePositionMS
                            guard end > start else { return }
                            onClipRequest(SubtitleClipDraft(item: item, durationMS: player.durationMS,
                                startMS: start, endMS: end))
                        } label: {
                            Label { Text("标记终点") } icon: { DecorativePlayerSymbol(name: "scissors") }
                        }
                        .disabled(player.positionMS <= start)
                        .accessibilityIdentifier("saveClip")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("标记终点")
                        .frame(minWidth: 44, minHeight: 44)

                        Button {
                            player.clearClipStart()
                            status = nil
                        } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("取消摘取")
                    } else {
                        Button {
                            status = nil
                            player.markClipStart()
                        } label: {
                            Label { Text("标记起点") } icon: { DecorativePlayerSymbol(name: "scissors") }
                        }
                        .disabled(player.durationMS <= 0 || player.positionMS >= player.durationMS)
                        .accessibilityIdentifier("markClipStart")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("标记起点")
                        .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
                if let status {
                    Text(status).font(.caption)
                } else if let start = player.clipStartMS {
                    Text("从 \(SubtitleTime.clock(start)) 开始，到结尾点「标记终点」确认时间")
                        .font(.caption)
                }
            }
            .onChange(of: item.id) { status = nil }
            .onChange(of: savedToken) { status = L10n.text("已保存到摘选") }
        }
    }
}
