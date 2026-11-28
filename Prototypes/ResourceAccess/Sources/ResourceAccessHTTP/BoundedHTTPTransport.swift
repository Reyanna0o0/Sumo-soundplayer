import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ResourceAccessCore

struct HTTPResponseBody {
    let response: HTTPURLResponse
    let data: Data
}

enum HTTPBodyExpectation {
    case headersOnly
    case bytes(expectedLength: Int?)
}

/// One session per bounded operation. No shared cookies, cached credentials, or
/// response cache. Header rejection cancels before collecting a response body.
final class BoundedHTTPTransport: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        self.configuration = copy
    }

    func perform(_ request: URLRequest, maximumBytes: Int,
                 redirectAllowed: @escaping @Sendable (URL) -> Bool,
                 inspect: @escaping @Sendable (HTTPURLResponse) throws -> HTTPBodyExpectation) async throws -> HTTPResponseBody {
        let operation = Operation(configuration: configuration, maximumBytes: maximumBytes,
                                  redirectAllowed: redirectAllowed, inspect: inspect)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start(request, continuation: $0) }
        } onCancel: { operation.cancel() }
    }

    private final class Operation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let configuration: URLSessionConfiguration
        private let maximumBytes: Int
        private let redirectAllowed: @Sendable (URL) -> Bool
        private let inspect: @Sendable (HTTPURLResponse) throws -> HTTPBodyExpectation
        private var continuation: CheckedContinuation<HTTPResponseBody, Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var cancelled = false
        private var finished = false
        private var response: HTTPURLResponse?
        private var expectedLength: Int?
        private var body = Data()
        private var redirects = 0

        init(configuration: URLSessionConfiguration, maximumBytes: Int,
             redirectAllowed: @escaping @Sendable (URL) -> Bool,
             inspect: @escaping @Sendable (HTTPURLResponse) throws -> HTTPBodyExpectation) {
            self.configuration = configuration; self.maximumBytes = maximumBytes
            self.redirectAllowed = redirectAllowed; self.inspect = inspect
        }

        func start(_ request: URLRequest, continuation: CheckedContinuation<HTTPResponseBody, Error>) {
            lock.lock()
            if cancelled {
                lock.unlock(); continuation.resume(throwing: ResourceAccessError.cancelled); return
            }
            self.continuation = continuation
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: request); self.task = task
            lock.unlock()
            task.resume()
        }

        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            finish(.failure(ResourceAccessError.cancelled))
        }

        private func finish(_ result: Result<HTTPResponseBody, Error>) {
            lock.lock()
            guard !finished, let continuation else { lock.unlock(); return }
            finished = true; self.continuation = nil
            let session = self.session; self.session = nil; task = nil
            lock.unlock()
            continuation.resume(with: result)
            session?.invalidateAndCancel()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            redirects += 1
            guard redirects <= 5, let destination = request.url, redirectAllowed(destination) else {
                completionHandler(nil)
                finish(.failure(ResourceAccessError.invalidResponse("Redirect leaves the selected origin/scope or exceeds limit")))
                return
            }
            // A redirect may not turn PROPFIND into GET. Reattach bounded-read
            // headers only after validating the same origin and selected scope.
            guard let original = task.originalRequest, original.httpMethod == request.httpMethod else {
                completionHandler(nil)
                finish(.failure(ResourceAccessError.invalidResponse("Redirect changes the resource operation")))
                return
            }
            var next = request
            next.allHTTPHeaderFields = original.allHTTPHeaderFields
            next.httpBody = original.httpBody
            next.httpShouldHandleCookies = false
            next.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            completionHandler(next)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, let url = http.url, redirectAllowed(url) else {
                completionHandler(.cancel)
                finish(.failure(ResourceAccessError.invalidResponse("Unexpected response origin or response type")))
                return
            }
            do {
                let expectation = try inspect(http)
                switch expectation {
                case .headersOnly:
                    completionHandler(.cancel)
                    finish(.success(HTTPResponseBody(response: http, data: Data())))
                case .bytes(let expected):
                    if let expected, expected > maximumBytes { throw ResourceAccessError.limitExceeded }
                    lock.lock(); self.response = http; expectedLength = expected; lock.unlock()
                    completionHandler(.allow)
                }
            } catch {
                completionHandler(.cancel); finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            guard data.count <= maximumBytes - body.count else {
                lock.unlock(); finish(.failure(ResourceAccessError.limitExceeded)); return
            }
            body.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(Self.classify(error))); return }
            lock.lock()
            let response = self.response, data = body, expected = expectedLength
            lock.unlock()
            guard let response else {
                finish(.failure(ResourceAccessError.invalidResponse("Missing HTTP response"))); return
            }
            if let expected, expected != data.count {
                finish(.failure(ResourceAccessError.invalidResponse("Response body length does not match declared range"))); return
            }
            finish(.success(HTTPResponseBody(response: response, data: data)))
        }

        // No server-trust override: URLSession performs normal TLS validation.
        private static func classify(_ error: Error) -> ResourceAccessError {
            let ns = error as NSError
            guard ns.domain == NSURLErrorDomain else { return .temporarilyUnavailable }
            switch ns.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: return .authorizationRequired
            case NSURLErrorNoPermissionsToReadFile: return .permissionDenied
            default: return .temporarilyUnavailable
            }
        }
    }
}
