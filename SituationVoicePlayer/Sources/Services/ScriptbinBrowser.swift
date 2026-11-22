import Foundation
import WebKit
import Combine

/// Only reads the script container of the requested page, never a site's terms/login shell.
@MainActor final class ScriptbinBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let link: DirectLink
    let webView: WKWebView
    @Published var status = InterfaceLocalization.text("正在打开网页…")
    @Published var loading = true
    @Published var canExtract = false
    @Published private(set) var hasFailed = false

    init(link: DirectLink) {
        self.link = link
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }
    func open() {
        hasFailed = false; loading = true; canExtract = false; status = InterfaceLocalization.text("正在打开网页…")
        webView.load(URLRequest(url: link.url, timeoutInterval: 45))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.scheme == "https", url.host == "scriptbin.works",
              url.user == nil, url.password == nil, url.port == nil,
              url.path == "/agree-terms" || url.path == link.url.path,
              action.targetFrame?.isMainFrame == true else {
            status = InterfaceLocalization.text("此链接需要额外访问，尚未导入。请使用可直接打开的 Scriptbin 台本链接。")
            loading = false; canExtract = false; hasFailed = true
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode != 200 {
            loading = false; canExtract = false; hasFailed = true
            status = InterfaceLocalization.text("网页读取失败（HTTP \(http.statusCode)），尚未导入。")
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; canExtract = false; hasFailed = false
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; hasFailed = false
        canExtract = webView.url?.path == link.url.path && webView.url?.host == "scriptbin.works"
        status = canExtract ? InterfaceLocalization.text("网页已打开。确认是所需台本后，点「提取正文」。") : InterfaceLocalization.text("请在网页内亲自确认访问条款；尚未导入。")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ error: Error) { loading = false; canExtract = false; hasFailed = true; status = InterfaceLocalization.text("网页未读取成功：") + error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false; canExtract = false; hasFailed = true
        status = InterfaceLocalization.text("网页进程已停止，尚未保存。可重新加载；已提取草稿仍保留。")
    }
    func extract() async throws -> ScriptbinDocument {
        guard canExtract, webView.url?.path == link.url.path, webView.url?.host == "scriptbin.works" else {
            throw DirectLinkError.message(InterfaceLocalization.text("当前还不是台本正文页，尚未导入。"))
        }
        let value = try await webView.callAsyncJavaScript(Self.extractJavaScript, arguments: [:], in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation()
        guard canExtract, webView.url?.path == link.url.path, webView.url?.host == "scriptbin.works" else {
            throw DirectLinkError.message(InterfaceLocalization.text("提取时网页已切换，请返回原台本页后重试。"))
        }
        guard let data = value as? [String: Any], let text = data["text"] as? String,
              let title = data["title"] as? String else { throw DirectLinkError.message(InterfaceLocalization.text("未找到 Scriptbin 正文，尚未导入。")) }
        return try ScriptbinDocument(link: link, title: title, text: text, description: data["description"] as? String ?? "")
    }
    // Selectors verified against Scriptbin's public site.js. The old/plain/new line modes must not include generated line-number tables twice.
    static let extractJavaScript = #"""
    if (location.pathname === '/agree-terms' || document.querySelector('input[type="password"]')) {
        throw new Error('请先完成网页访问，尚未读取正文。');
    }
    let text = '';
    const plain = document.querySelector('.script-text-real');
    if (plain) {
        let lines = plain.querySelectorAll('.line-raw');
        if (!lines.length) lines = plain.querySelectorAll('.line-txt');
        if (lines.length) text = Array.from(lines, n => n.textContent).join('\n');
        else throw new Error('台本排版无法识别，尚未导入。');
    } else {
        const roots = Array.from(document.querySelectorAll('.markdown-script-real'))
            .filter(n => !n.parentElement.closest('.markdown-script-real'));
        if (!roots.length) throw new Error('未找到台本正文，可能需要登录、密码或已失效。');
        text = roots.map(n => n.innerText).join('\n\n');
    }
    if (!text.trim() || text.length > 2097152) throw new Error('台本正文为空或超过大小上限。');
    return {text, title: document.querySelector('meta[property="og:title"]')?.content || '',
        description: document.querySelector('meta[property="og:description"]')?.content || ''};
    """#
}
