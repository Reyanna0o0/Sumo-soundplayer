# HTTP / WebDAV adapter verification

`ResourceAccessHTTP.HTTPResourceAdapter` is a real URLSession adapter for the shared `ResourceAdapter` contract. It accepts `.http` or `.webDAV` connections. `endpoint` is an explicitly chosen root; every operation supplies a raw, relative `ResourcePath`. A connection is not an instruction to scan or import its entire tree.

Implemented behavior:

- Metadata uses `HEAD`. Range reads use a closed byte interval with a maximum 1 MiB requested body, validate `206` and the exact `Content-Range` start/end/total, require a matching body length, and allow a correctly truncated range at EOF. A `200` that ignores `Range` is rejected before retaining its body. `Accept-Ranges` alone never proves random access.
- `probe` checks byte 0 and, for a known size above 1 byte, an actual nonzero offset. It leaves media seek accuracy, direct playback, complete downloads, and resumable downloads unknown. Those are separate application/player/copy-manager responsibilities.
- Read-only WebDAV uses namespaced `PROPFIND Depth: 1`, bounded to 2 MiB XML and 2,000 immediate children by default. It neither recursively visits children nor changes a catalog. UTF-8 XML only; DTD/entity declarations, external entities, malformed XML, duplicate children, and paths outside the selected directory are rejected. An incomplete/failed listing throws instead of producing a partial catalog that could trigger deletion.
- Credentials come from the opaque `CredentialReference` via `CredentialProvider`; only HTTP Basic or Bearer are supported here. They are not serialized into resource URLs. Cookies and shared credential/cache storage are disabled. Cross-origin and out-of-root redirects are rejected entirely. Same-origin redirects must retain the operation and bounded-read headers. TLS validation uses URLSession defaults, with no trust bypass. Plain HTTP requires the Core connection's explicit opt-in.
- `401/403`, missing resources, transient server failures, timeout, and task cancellation remain distinct errors. Authenticated resources yield `.byteReader`, not a claim that an unauthenticated AVPlayer URL will work.

Deliberate limits:

- `HEAD` 405/501 is currently `unsupported`; no GET fallback yet. This is not compatibility with every HTTP/WebDAV server. Servers returning unknown total lengths, compressed range bodies, non-UTF-8 DAV XML, query-based signed URLs, Digest/NTLM auth, or redirects outside the selected root need a separate explicit design.
- Size/mtime alone never prove file identity. A read rejects a definitely changed revision but can return an unknown comparison. Consumers must inspect the returned revision and require strong evidence before joining retained bytes or resuming a partial copy; a successful byte range does not prove safe resume.
- Bounded retained application data does not promise that zero extra bytes reach the OS/network buffer before cancellation. It prevents accidentally collecting a whole ignored-range response in app memory.
- This target does not implement an AVPlayer resource loader, background downloads, media decoding, or NAS discovery. A remote `fileURL` from Files is outside this adapter's protocol contract.

Tests:

- `HTTPResourceAdapterTests`: URLProtocol-controlled metadata, credentials, exact/EOF/malformed ranges, revision change, ignored Range, error classification, cancellation, and conservative capability claims.
- `WebDAVResourceAdapterTests`: real XML parser, namespaces, Unicode/space/literal-percent names, `Depth: 1`, subtree limits, optional missing properties, duplicate/error listing, DTD/entity rejection, body/entry limits, and authenticated playback handoff.
- `HTTPIntegrationTests` (macOS): launches `protocol_server.py` using `/usr/bin/python3`. It binds two ephemeral ports **only on 127.0.0.1**, uses synthetic 4 KiB bytes and disposable test credentials, and terminates the fixture after each test. Real URLSession verifies HEAD/Range, Unicode paths, same-origin redirect/auth preservation, PROPFIND, ignored Range, and that cross-origin redirects produce zero destination visits. A prohibited loopback bind fails the test rather than being counted as a pass.

Run from `Prototypes/ResourceAccess` with loopback sockets permitted:

```sh
swift test --filter 'HTTPIntegrationTests|HTTPResourceAdapterTests|WebDAVResourceAdapterTests'
```

The fixture never accesses a real NAS or external host. These checks do not establish real-NAS compatibility, trusted HTTPS deployment, iPhone network permissions, or AVPlayer streaming/seek performance.

Protocol references: [HTTP ranges and Content-Range, RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#section-14), [WebDAV PROPFIND and Depth, RFC 4918](https://www.rfc-editor.org/rfc/rfc4918.html#section-9.1). No third-party implementation was copied.
