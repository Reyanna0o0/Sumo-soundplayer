import AVFoundation
import Foundation
import ResourceAccessCore
import UniformTypeIdentifiers

/// AVPlayer byte bridge owned by the formal playback session. It does not implement a persistent cache.
/// Our payload buffers are at most two 128 KiB reads; AVFoundation and the SMB
/// SDK manage additional buffers. An SDK read may finish after cancellation.
final class NetworkResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "sumo-network-audio"
    let queue = DispatchQueue(label: "sumo.network.resource-loader")
    let url: URL
    private let adapter: any ResourceAdapter
    private let path: ResourcePath
    private let metadata: ResourceMetadata
    private let contentType: String
    private let onBytes: @Sendable (Int64) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let chunkSize = 128 * 1_024
    private let maximumWorkers = 2
    private var cumulativeBytes: Int64 = 0
    private var activeWorkers = 0
    private var invalidated = false
    private var waiting: [ObjectIdentifier] = []
    private var requests: [ObjectIdentifier: Pending] = [:]

    private final class Pending {
        let token = UUID()
        let request: AVAssetResourceLoadingRequest
        let plan: NetworkByteRangePlan?
        var task: Task<Void, Never>?
        init(_ request: AVAssetResourceLoadingRequest, plan: NetworkByteRangePlan?) {
            self.request = request; self.plan = plan
        }
    }

    init(adapter: any ResourceAdapter, path: ResourcePath, metadata: ResourceMetadata,
         onBytes: @escaping @Sendable (Int64) -> Void,
         onFailure: @escaping @Sendable (Error) -> Void) throws {
        guard !metadata.isDirectory, let size = metadata.size, size > 0 else { throw NetworkLoaderFailure.invalidMetadata }
        self.adapter = adapter; self.path = path; self.metadata = metadata
        self.onBytes = onBytes; self.onFailure = onFailure
        let ext = (path.components.last.map { ($0 as NSString).pathExtension } ?? "").lowercased()
        let byExtension = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        let byMIME = metadata.mimeType.flatMap { UTType(mimeType: $0) }
        guard let type = [byExtension, byMIME].compactMap({ $0 }).first(where: { $0.conforms(to: .audio) || $0.conforms(to: .audiovisualContent) }) else {
            throw NetworkLoaderFailure.unsupportedType
        }
        contentType = type.identifier
        // No source address, directory, user, password, or real filename enters this URL.
        url = URL(string: "\(Self.scheme)://\(UUID().uuidString)/media.\(type.preferredFilenameExtension ?? "bin")")!
        super.init()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme == Self.scheme else { return false }
        guard !invalidated else {
            request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)); return true
        }
        do {
            guard requests.count < 16 else { throw ResourceAccessError.limitExceeded }
            if let info = request.contentInformationRequest {
                info.contentType = contentType
                info.contentLength = metadata.size!
                info.isByteRangeAccessSupported = true
            }
            let plan = try request.dataRequest.map {
                try NetworkByteRangePlan(requestedOffset: $0.requestedOffset, currentOffset: $0.currentOffset,
                    requestedLength: $0.requestedLength, requestsToEnd: $0.requestsAllDataToEndOfResource,
                    fileSize: metadata.size!)
            }
            guard let plan, plan.start < plan.endExclusive else { request.finishLoading(); return true }
            let id = ObjectIdentifier(request)
            requests[id] = Pending(request, plan: plan)
            waiting.append(id)
            pump()
        } catch { request.finishLoading(with: error); onFailure(error) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(request)
        requests.removeValue(forKey: id)?.task?.cancel()
        waiting.removeAll { $0 == id }
        // Keep an occupied worker counted until its non-cancellable SDK read returns.
        pump()
    }

    func invalidate() {
        queue.async { [self] in
            invalidated = true
            let abandoned = Array(requests.values)
            requests.removeAll(); waiting.removeAll()
            for pending in abandoned {
                pending.task?.cancel()
                pending.request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            }
        }
    }

    func bytesReadSnapshot() async -> Int64 {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: cumulativeBytes) }
        }
    }

    private func pump() {
        while !invalidated, activeWorkers < maximumWorkers, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let pending = requests[id], let plan = pending.plan else { continue }
            activeWorkers += 1
            let token = pending.token
            pending.task = Task { [weak self] in await self?.serve(id: id, token: token, plan: plan) }
        }
    }

    private func serve(id: ObjectIdentifier, token: UUID, plan: NetworkByteRangePlan) async {
        var offset = plan.start
        do {
            while offset < plan.endExclusive {
                try Task.checkCancellation()
                let length = plan.nextLength(at: offset, maximum: chunkSize)
                let chunk = try await adapter.read(at: path, range: ByteRange(offset: offset, length: length),
                                                   expectedRevision: metadata.revision)
                // Count all successful returned bytes, including rereads. Never call this unique coverage.
                await countBytes(chunk.data.count)
                try Task.checkCancellation()
                guard chunk.offset == offset, chunk.data.count == length else { throw NetworkLoaderFailure.truncatedData }
                if let total = chunk.totalLength, total != metadata.size { throw NetworkLoaderFailure.changedResource }
                guard metadata.revision.match(chunk.revision) != .different else { throw NetworkLoaderFailure.changedResource }
                guard await respond(chunk.data, id: id, token: token) else { throw CancellationError() }
                offset += Int64(chunk.data.count)
            }
            finish(id: id, token: token, error: nil)
        } catch { finish(id: id, token: token, error: error) }
    }

    private func countBytes(_ count: Int) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let sum = cumulativeBytes.addingReportingOverflow(Int64(count))
                cumulativeBytes = sum.overflow ? Int64.max : sum.partialValue
                onBytes(cumulativeBytes)
                continuation.resume()
            }
        }
    }

    private func respond(_ data: Data, id: ObjectIdentifier, token: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !invalidated, let pending = requests[id], pending.token == token,
                      !pending.request.isCancelled else { continuation.resume(returning: false); return }
                pending.request.dataRequest?.respond(with: data)
                continuation.resume(returning: true)
            }
        }
    }

    private func finish(id: ObjectIdentifier, token: UUID, error: Error?) {
        queue.async { [self] in
            activeWorkers = max(0, activeWorkers - 1)
            if let pending = requests[id], pending.token == token {
                requests[id] = nil
                if !pending.request.isCancelled {
                    if let error { pending.request.finishLoading(with: error) }
                    else { pending.request.finishLoading() }
                }
                if let error, !(error is CancellationError), !invalidated { onFailure(error) }
            }
            pump()
        }
    }
}
