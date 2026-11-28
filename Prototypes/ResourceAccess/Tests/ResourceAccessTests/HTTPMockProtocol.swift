import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import ResourceAccessCore
@testable import ResourceAccessHTTP

final class HTTPMockProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: Error?
        var delay: TimeInterval = 0
    }
    private static let mutex = NSLock()
    private static var responseHandler: ((URLRequest) -> Reply)?
    private static var captured: [URLRequest] = []
    private let mutex = NSLock()
    private var stopped = false
    static func install(_ handler: @escaping (URLRequest) -> Reply) {
        mutex.lock(); captured = []; responseHandler = handler; mutex.unlock()
    }
    static var requests: [URLRequest] { mutex.lock(); defer { mutex.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.mutex.lock(); Self.captured.append(request); let handler = Self.responseHandler; Self.mutex.unlock()
        guard let reply = handler?(request) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
            guard let self else { return }
            self.mutex.lock(); let stopped = self.stopped; self.mutex.unlock()
            guard !stopped else { return }
            if let error = reply.error { self.client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { self.client?.urlProtocol(self, didLoad: reply.body) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { mutex.lock(); stopped = true; mutex.unlock() }
}

func httpMockAdapter(kind: SourceKind = .http, credentialReference: CredentialReference? = nil,
                     credentials: any CredentialProvider = InMemoryCredentialStore(),
                     maximumListingBytes: Int = 2_097_152, maximumEntries: Int = 2_000) throws -> HTTPResourceAdapter {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HTTPMockProtocol.self]
    let connection = try SourceConnection(kind: kind, endpoint: URL(string: "http://fixture.invalid/selected/")!,
                                          credentialReference: credentialReference, allowsInsecureHTTP: true)
    return try HTTPResourceAdapter(connection: connection, credentials: credentials, configuration: configuration,
                                   maximumListingBytes: maximumListingBytes, maximumEntries: maximumEntries)
}

func assertAccessError(_ expected: ResourceAccessError? = nil, file: StaticString = #filePath, line: UInt = #line,
                       operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("Expected ResourceAccessError", file: file, line: line) }
    catch let error as ResourceAccessError { if let expected { XCTAssertEqual(error, expected, file: file, line: line) } }
    catch { XCTFail("Unexpected error type: \(error)", file: file, line: line) }
}
