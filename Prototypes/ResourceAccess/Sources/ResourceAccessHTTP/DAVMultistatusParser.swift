import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ResourceAccessCore

struct DAVRecord {
    let href: String
    let metadata: ResourceMetadata
}

/// Namespaced, bounded UTF-8 DAV XML. DTDs and entity declarations are rejected
/// before parsing; no external entity resolution or entity expansion is allowed.
final class DAVMultistatusParser: NSObject, XMLParserDelegate {
    private struct Element: Equatable { let namespace: String; let name: String }
    private struct Properties {
        var isDirectory: Bool?
        var size: Int64?
        var mime: String?
        var etag: String?
        var modified: Date?
        var invalidLength = false
        mutating func merge(_ other: Self) {
            if let value = other.isDirectory { isDirectory = value }
            if let value = other.size { size = value }
            if let value = other.mime { mime = value }
            if let value = other.etag { etag = value }
            if let value = other.modified { modified = value }
        }
    }
    private let maximumEntries: Int
    private var stack: [Element] = []
    private var textStack: [String] = []
    private var records: [DAVRecord] = []
    private var failure: Error?
    private var href: String?
    private var responseStatus: Int?
    private var properties = Properties()
    private var current = Properties()
    private var propstatStatus: Int?
    private var sawMultistatus = false

    private init(maximumEntries: Int) { self.maximumEntries = maximumEntries }

    static func parse(_ data: Data, maximumEntries: Int) throws -> [DAVRecord] {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ResourceAccessError.invalidResponse("Only UTF-8 XML without DTD/entity declarations is accepted")
        }
        let delegate = DAVMultistatusParser(maximumEntries: maximumEntries)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let success = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard success, delegate.sawMultistatus, delegate.stack.isEmpty else {
            throw ResourceAccessError.invalidResponse("Malformed DAV multistatus XML")
        }
        return delegate.records
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        stack.append(Element(namespace: namespaceURI ?? "", name: elementName)); textStack.append("")
        guard stack.count <= 32 else { fail(parser, .limitExceeded); return }
        if stack.count == 1 {
            guard isPath(["multistatus"]) else { fail(parser, .invalidResponse("Expected DAV multistatus root")); return }
            sawMultistatus = true
        }
        if isPath(["multistatus", "response"]) {
            href = nil; responseStatus = nil; properties = Properties()
        } else if isPath(["multistatus", "response", "propstat"]) {
            current = Properties(); propstatStatus = nil
        } else if isPath(["multistatus", "response", "propstat", "prop", "resourcetype"]) {
            current.isDirectory = false
        } else if isPath(["multistatus", "response", "propstat", "prop", "resourcetype", "collection"]) {
            current.isDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !textStack.isEmpty else { return }
        guard textStack[textStack.count - 1].utf8.count + string.utf8.count <= 65_536 else {
            fail(parser, .limitExceeded); return
        }
        textStack[textStack.count - 1] += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let text = textStack.last?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        defer { stack.removeLast(); textStack.removeLast() }
        if isPath(["multistatus", "response", "href"]) {
            if href != nil { fail(parser, .invalidResponse("Duplicate DAV href")); return }; href = text
        } else if isPath(["multistatus", "response", "status"]) {
            responseStatus = statusCode(text)
            if responseStatus == nil { fail(parser, .invalidResponse("Invalid DAV response status")) }
        } else if isPath(["multistatus", "response", "propstat", "status"]) {
            propstatStatus = statusCode(text)
        } else if stack.count == 5, Array(stack.prefix(4)) == dav(["multistatus", "response", "propstat", "prop"]), namespaceURI == "DAV:" {
            switch elementName {
            case "getcontentlength":
                if let size = Int64(text), size >= 0 { current.size = size }
                else { current.invalidLength = true }
            case "getcontenttype": current.mime = text.isEmpty ? nil : text
            case "getetag": current.etag = text.isEmpty ? nil : text
            case "getlastmodified": current.modified = HTTPDate.parse(text)
            default: break
            }
        } else if isPath(["multistatus", "response", "propstat"]) {
            guard let status = propstatStatus else { fail(parser, .invalidResponse("Missing DAV propstat status")); return }
            if (200..<300).contains(status) {
                guard !current.invalidLength else { fail(parser, .invalidResponse("Invalid successful DAV content length")); return }
                properties.merge(current)
            }
        } else if isPath(["multistatus", "response"]) {
            if let status = responseStatus, !(200..<300).contains(status) {
                fail(parser, status == 401 ? .authorizationRequired : status == 403 ? .permissionDenied : .invalidResponse("DAV child lookup failed")); return
            }
            guard let href, !href.isEmpty, let isDirectory = properties.isDirectory else {
                fail(parser, .invalidResponse("DAV response lacks href or a successful resource type")); return
            }
            guard records.count < maximumEntries else { fail(parser, .limitExceeded); return }
            let metadata = ResourceMetadata(size: properties.size, mimeType: properties.mime, isDirectory: isDirectory,
                                            revision: ResourceRevision(size: properties.size, etag: properties.etag, modifiedAt: properties.modified))
            records.append(DAVRecord(href: href, metadata: metadata))
        }
    }

    private func dav(_ names: [String]) -> [Element] { names.map { Element(namespace: "DAV:", name: $0) } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let value = String(data: CDATABlock, encoding: .utf8) else { fail(parser, .invalidResponse("Invalid XML text encoding")); return }
        self.parser(parser, foundCharacters: value)
    }
    private func isPath(_ names: [String]) -> Bool { stack == dav(names) }
    private func statusCode(_ text: String) -> Int? {
        let values = text.split(separator: " ", omittingEmptySubsequences: true)
        guard values.count >= 2, values[0].hasPrefix("HTTP/"), let code = Int(values[1]), (100...599).contains(code) else { return nil }
        return code
    }
    private func fail(_ parser: XMLParser, _ error: ResourceAccessError) { if failure == nil { failure = error }; parser.abortParsing() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(parser, .invalidResponse("External entities are forbidden")); return nil
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser, .invalidResponse("Entity declarations are forbidden"))
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail(parser, .invalidResponse("Entity declarations are forbidden"))
    }
}
