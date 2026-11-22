import SwiftUI
import UIKit

/// 导入已经落库时，在当前页面中央短暂提示，下面的控件仍可点按。
struct ImportSuccessToast: View {
    var title: LocalizedStringKey = "导入成功"
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 5) {
            Label(title, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 300)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

extension EnvironmentValues {
    /// A successful destination selection is reported to its visible playback page.
    /// Keeping the receipt outside the sheet lets dismissal reveal the message.
    @Entry var playlistAdditionSucceeded: (String) -> Void = { _ in }
}

private struct PlaylistAdditionFeedback: ViewModifier {
    private struct Receipt: Identifiable {
        let id = UUID()
        let listName: String
    }
    @State private var receipt: Receipt?

    func body(content: Content) -> some View {
        content
            .environment(\.playlistAdditionSucceeded) { name in
                withAnimation(.easeOut(duration: 0.15)) { receipt = Receipt(listName: name) }
            }
            .overlay {
                if let receipt {
                    ImportSuccessToast(title: "已加入「\(receipt.listName)」")
                        .accessibilityIdentifier("playlistAdditionSuccess")
                }
            }
            .task(id: receipt?.id) {
                guard let current = receipt else { return }
                UIAccessibility.post(notification: .announcement,
                    argument: L10n.text("已加入「\(current.listName)」"))
                do { try await Task.sleep(for: .milliseconds(2600)) } catch { return }
                guard receipt?.id == current.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { receipt = nil }
            }
    }
}

struct SubtitleImportReceipt: Identifiable {
    let id = UUID()
    let detail: String
}

extension View {
    func playlistAdditionFeedback() -> some View {
        modifier(PlaylistAdditionFeedback())
    }

    func subtitleImportReceipt(_ receipt: Binding<SubtitleImportReceipt?>) -> some View {
        overlay {
            if let result = receipt.wrappedValue {
                ImportSuccessToast(detail: result.detail)
            }
        }
        .task(id: receipt.wrappedValue?.id) {
            guard let result = receipt.wrappedValue else { return }
            UIAccessibility.post(notification: .announcement, argument: L10n.text("导入成功。\(result.detail)"))
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            withAnimation(.easeOut(duration: 0.2)) { receipt.wrappedValue = nil }
        }
    }
}
