import SwiftUI
import WebKit

/// Navigation owns the extracted value. A pushed preview can never be backed by
/// an optional @State which was nil when SwiftUI registered its destination.
@MainActor final class ScriptbinImportSession: ObservableObject {
    struct Preview: Hashable {
        let id = UUID()
        let document: ScriptbinDocument
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    enum Step: Hashable { case web(ScriptbinBrowser), preview(Preview), mapping(Preview) }
    @Published var route: [Step] = []
    @Published var drafts: [ScriptReviewFile] = []
    @Published private(set) var latestPreview: Preview?
    private(set) var browser: ScriptbinBrowser?
    var tracks: [TrackRecord] = []

    init(browser: ScriptbinBrowser? = nil) {
        self.browser = browser
        if let browser { route = [.web(browser)] }
    }
    func open(_ input: String) throws {
        let next = ScriptbinBrowser(link: try DirectLink(input, site: .scriptbin))
        browser?.webView.stopLoading()
        browser = next
        route = [.web(next)]
        // Keep an already extracted draft until another extraction succeeds.
        next.open()
    }
    func didRead(_ document: ScriptbinDocument, from browser: ScriptbinBrowser) throws {
        guard self.browser === browser, let current = route.last, case .web(let visible) = current, visible === browser,
              document.metadata.sourceURL == browser.link.url.absoluteString else {
            throw DirectLinkError.message(L10n.text("网页已切换；原草稿保留，请重新核对当前网页。"))
        }
        let preview = Preview(document: document)
        drafts = [ScriptReviewFile(name: "Scriptbin · " + document.metadata.title,
                                  sections: [document.section], tracks: tracks)]
        latestPreview = preview
        route.append(.preview(preview))
    }
    func resumePreview() {
        if let latestPreview { route.append(.preview(latestPreview)) }
    }
}

@MainActor
struct ScriptbinImportSheet: View {
    let work: WorkRecord
    let store: LibraryStore
    var onImported: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subtitles: SubtitleController
    @State private var input = ""
    @StateObject private var session: ScriptbinImportSession
    @State private var tracks: [TrackRecord] = []
    @State private var errorText: String?

    init(work: WorkRecord, store: LibraryStore, session: ScriptbinImportSession? = nil,
         onImported: @escaping () -> Void = {}) {
        self.work = work; self.store = store; self.onImported = onImported
        _session = StateObject(wrappedValue: session ?? ScriptbinImportSession())
    }

    var body: some View {
        NavigationStack(path: $session.route) {
            linkForm
                .appNavigationColors().navigationTitle(L10n.text("导入 Scriptbin"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .navigationDestination(for: ScriptbinImportSession.Step.self) { step in
                    destination(for: step)
                }
        }
        .task {
            tracks = store.tracks(for: work).filter { !$0.isVideo }
            session.tracks = tracks
        }
        .onDisappear { session.browser?.webView.stopLoading() }
    }

    private var linkForm: some View {
        AppForm {
                Section {
                    TextField("https://scriptbin.works/u/…/…", text: $input)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("scriptbinURL")
                    Button("打开台本网页") {
                        do {
                            try session.open(input)
                            errorText = nil
                        } catch { errorText = error.localizedDescription }
                    }.accessibilityIdentifier("scriptbinOpen")
                } header: { Text("Scriptbin 台本链接") }
                  footer: {
                    Text("在网页内确认访问后，提取一次正文并保存到「\(work.title)」的台本。保存后可离线阅读，已有台本和编辑版本保留。")
                }
                if let preview = session.latestPreview {
                    Section("已提取，尚未保存") {
                        Button("继续核对已提取正文", action: session.resumePreview)
                            .accessibilityIdentifier("scriptbinResumeDraft")
                        Text(preview.document.metadata.title).font(.caption).lineLimit(2)
                    }
                }
                if let errorText { Text(errorText).foregroundStyle(.orange) }
        }
    }

    private func resumeAction(for browser: ScriptbinBrowser) -> (() -> Void)? {
        guard session.latestPreview?.document.metadata.sourceURL == browser.link.url.absoluteString else { return nil }
        return { session.resumePreview() }
    }

    @ViewBuilder private func destination(for step: ScriptbinImportSession.Step) -> some View {
        switch step {
                case .web(let browser):
                    ScriptbinWebPage(browser: browser, resumeDraft: resumeAction(for: browser)) { value in
                        try session.didRead(value, from: browser)
                    }
                case .preview(let preview):
                    ScriptbinBodyPreview(document: preview.document)
                        .appNavigationColors().navigationTitle(L10n.text("核对正文"))
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("选择音轨") { session.route.append(.mapping(preview)) }.accessibilityIdentifier("scriptbinMap")
                        } }
                case .mapping(let preview):
                    ScriptMappingReview(files: $session.drafts, tracks: tracks, mergedCopies: 0) { activate in
                        try await save(preview: preview, activate: activate)
                    }
        }
    }
    private func save(preview: ScriptbinImportSession.Preview, activate: Bool) async throws {
        guard session.latestPreview?.id == preview.id else { throw DirectLinkError.message(L10n.text("提取内容已更新，请返回核对最新正文；原有台本未改动。")) }
        let files = session.drafts.map { (name: $0.name, rows: $0.rows) }
        try store.importScriptbin(preview.document, into: work, files: files, activate: activate)
        if let id = subtitles.loadedTrackID, session.drafts.flatMap(\.rows).contains(where: { $0.trackID == id }) { subtitles.forceReload() }
        onImported(); dismiss()
    }
}

private struct ScriptbinBodyPreview: View {
    let document: ScriptbinDocument
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DirectLinkDetails(metadata: document.metadata).padding()
            Divider()
            ScriptbinPreviewText(text: document.text)
        }
        .accessibilityIdentifier("scriptbinPreviewPage")
    }
}

/// Read-only native scrolling avoids laying out a potentially 2 MB SwiftUI Text
/// as one unbounded cell before the preview becomes visible.
private struct ScriptbinPreviewText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 20, right: 12)
        view.accessibilityIdentifier = "scriptbinBodyPreview"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text; view.setContentOffset(.zero, animated: false) }
    }
}

private struct ScriptbinWebPage: View {
    @ObservedObject var browser: ScriptbinBrowser
    let resumeDraft: (() -> Void)?
    let onRead: (ScriptbinDocument) throws -> Void
    @State private var extracting = false
    @State private var errorText: String?
    @State private var extraction: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Text(errorText ?? browser.status).font(.footnote).padding(10)
                .accessibilityIdentifier("scriptbinStatus")
            if errorText != nil || browser.hasFailed {
                HStack {
                    Button("重新加载网页") { errorText = nil; browser.open() }
                    Button("返回链接") { dismiss() }
                }.padding(.bottom, 8)
            }
            if let resumeDraft {
                Button("继续核对已提取正文", action: resumeDraft)
                    .accessibilityIdentifier("scriptbinResumeDraft").padding(.bottom, 8)
            }
            if browser.loading || extracting { ProgressView() }
            ScriptbinWebView(webView: browser.webView)
        }
        .appNavigationColors().navigationTitle(L10n.text("Scriptbin 网页"))
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("提取正文") {
                extracting = true; errorText = nil
                extraction = Task {
                    defer { extracting = false }
                    do {
                        let document = try await browser.extract()
                        try Task.checkCancellation()
                        try onRead(document)
                    } catch is CancellationError { /* Leaving the page does not push a late destination. */ }
                    catch { errorText = L10n.text("正文提取未完成：") + error.localizedDescription }
                }
            }.disabled(!browser.canExtract || browser.loading || extracting)
             .accessibilityIdentifier("scriptbinExtract")
        } }
        .onDisappear { extraction?.cancel(); extraction = nil; extracting = false }
    }
}
private struct ScriptbinWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
