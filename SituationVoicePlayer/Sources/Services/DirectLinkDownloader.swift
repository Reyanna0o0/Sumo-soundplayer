import Foundation

/// Bounded download to a new temporary file. Rejects untrusted redirects before following them.
final class DirectLinkDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let allowed: @Sendable (URL) -> Bool
    private let limit: Int64
    private let destination: URL
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var continuation: CheckedContinuation<URL, Error>?
    private var failure: Error?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    private var cancelled = false
    private let progress: @Sendable (Int64, Int64) -> Void

    private init(limit: Int64, destination: URL, allowed: @escaping @Sendable (URL) -> Bool,
                 progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.limit = limit; self.destination = destination; self.allowed = allowed; self.progress = progress
    }
    static func fetch(_ url: URL, limit: Int64, extension ext: String,
                      allowed: @escaping @Sendable (URL) -> Bool,
                      progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
        guard allowed(url) else { throw DirectLinkError.message(InterfaceLocalization.text("来源地址不受支持，尚未导入。")) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("simo-link-" + UUID().uuidString).appendingPathExtension(ext)
        let transfer = DirectLinkDownloader(limit: limit, destination: destination, allowed: allowed, progress: progress)
        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation { continuation in transfer.start(url, continuation) }
            do { try Task.checkCancellation(); return result }
            catch { try? FileManager.default.removeItem(at: result); throw error }
        } onCancel: { transfer.cancel() }
    }
    private func start(_ url: URL, _ continuation: CheckedContinuation<URL, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            self.continuation = nil; continuation.resume(throwing: DirectLinkError.message(InterfaceLocalization.text("无法创建下载副本。"))); return
        }
        do { handle = try FileHandle(forWritingTo: destination) }
        catch { self.continuation = nil; try? FileManager.default.removeItem(at: destination); continuation.resume(throwing: error); return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 1800
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request); self.task = task; task.resume()
    }
    private func cancel() { lock.lock(); cancelled = true; task?.cancel(); lock.unlock() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, allowed(url) else {
            failure = DirectLinkError.message(InterfaceLocalization.text("链接跳转到不支持的地址，尚未导入。"))
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, allowed(url) else {
            failure = DirectLinkError.message(InterfaceLocalization.text("网页或音频读取失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)），尚未导入。"))
            completionHandler(.cancel); return
        }
        expected = response.expectedContentLength
        guard expected <= limit else { failure = DirectLinkError.message(InterfaceLocalization.text("文件超过本次导入大小上限。") ); completionHandler(.cancel); return }
        do {
            let space = try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard space > max(expected, 0) * 2 + 128 * 1024 * 1024 else { throw DirectLinkError.message(InterfaceLocalization.text("剩余空间不足以下载并保存音频副本。")) }
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard received + Int64(data.count) <= limit else { failure = DirectLinkError.message(InterfaceLocalization.text("下载超过大小上限，尚未导入。") ); dataTask.cancel(); return }
        do { try handle?.write(contentsOf: data); received += Int64(data.count); progress(received, expected) }
        catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.close() } catch { if failure == nil { failure = error } }; handle = nil
        lock.lock(); let wasCancelled = cancelled; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        let problem: Error? = wasCancelled ? CancellationError() : (failure ?? error)
        if let problem { try? FileManager.default.removeItem(at: destination); continuation?.resume(throwing: problem) }
        else if received == 0 || (expected >= 0 && received != expected) {
            try? FileManager.default.removeItem(at: destination)
            continuation?.resume(throwing: DirectLinkError.message(InterfaceLocalization.text("下载不完整，尚未导入。")))
        } else { continuation?.resume(returning: destination) }
        session.finishTasksAndInvalidate(); self.session = nil; self.task = nil
    }
}

enum SoundgasmImporter {
    static func read(_ link: DirectLink) async throws -> SoundgasmPage {
        let url = try await DirectLinkDownloader.fetch(link.url, limit: 2 * 1024 * 1024, extension: "html", allowed: {
            guard let next = try? DirectLink($0.absoluteString, site: .soundgasm) else { return false }
            return next.url == link.url
        })
        defer { try? FileManager.default.removeItem(at: url) }
        guard let html = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw DirectLinkError.message(InterfaceLocalization.text("网页文字编码无法读取。")) }
        return try SoundgasmPage.parse(html: html, link: link)
    }
}
