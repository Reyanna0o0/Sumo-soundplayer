import Foundation

/// Pure arithmetic used by the resource-loader delegate. No URL or credential data.
struct NetworkByteRangePlan: Equatable {
    let start: Int64
    let endExclusive: Int64
    init(requestedOffset: Int64, currentOffset: Int64, requestedLength: Int,
         requestsToEnd: Bool, fileSize: Int64) throws {
        guard requestedOffset >= 0, currentOffset >= 0, requestedLength >= 0, fileSize >= 0 else {
            throw NetworkLoaderFailure.invalidRange
        }
        let cursor = max(requestedOffset, currentOffset)
        let end: Int64
        if requestsToEnd { end = fileSize }
        else {
            let sum = requestedOffset.addingReportingOverflow(Int64(requestedLength))
            guard !sum.overflow else { throw NetworkLoaderFailure.invalidRange }
            end = min(fileSize, sum.partialValue)
        }
        start = min(cursor, fileSize)
        endExclusive = max(start, end)
    }
    func nextLength(at offset: Int64, maximum: Int) -> Int {
        guard offset >= start, offset < endExclusive, maximum > 0 else { return 0 }
        return Int(min(Int64(maximum), endExclusive - offset))
    }
}

enum NetworkLoaderFailure: Error {
    case invalidRange, invalidMetadata, truncatedData, changedResource, unsupportedType
}
