# Local Sumo resource probe patch — 2026-11-25

This is a complete source copy, not an upstream release or an upstream-endorsed fix. No upstream repository was changed or published. Git metadata, build caches and downloaded tools are omitted; the original source, headers, build scripts, examples and license notices are retained.

## Exact provenance

- AMSMB2 4.0.3: `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`, https://github.com/amosavian/AMSMB2
- Included libsmb2 submodule: `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03`, https://github.com/sahlberg/libsmb2
- `SUMO_UPSTREAM_FILES.json` records every copied upstream file SHA-256 before modification.
- `SUMO_PATCH.diff` is the exact unified source patch, applicable with `patch -p1` at the clean SDK root after checking out the pinned submodule.
- `SUMO_SOURCE_FILES.json` records the delivered upstream/source files after modification. Supplemental provenance documents are listed separately and are not recursive self hashes.

## Changes and reason

1. `Context.swift`: capture error text and NTSTATUS before context destruction. Accept a terminal callback after SESSION_SETUP has closed its fd. Reset stale NTSTATUS at the start of each operation and carry a failed callback's actual NTSTATUS. Use a stable callback object pointer for the entire operation, cancel unfinished callbacks before returning on timeout, and keep that object alive through context destruction. Removing the closed-fd guard exposed a real timeout/deinit stale-stack-pointer crash; the added lifetime handling fixes it rather than hiding the negative test.
2. `Extensions.swift` and new `SMB2ErrorMetadata.swift`: add optional numeric `AMSMB2.NTStatus` to NSError/POSIXError metadata. Existing callers remain source-compatible; consumers need not inspect descriptions.
3. `socket.c`: stop the receive loop after a terminal callback closes its socket, avoiding readv(-1) after successful LOGOFF or rejected SESSION_SETUP. Preserve actual socket errno (including a negative next-address result) rather than replacing every connection error with generic -1.
4. `libsmb2.c`: propagate actual failed TREE_DISCONNECT/LOGOFF status instead of reporting LOGOFF success or replacing TREE_DISCONNECT failure with ENOMEM.

There are no changes to signing verification, authentication exchange, credentials, cipher selection or encryption requirements. The client does not retry rejected explicit credentials as guest. A server that independently maps users to a guest session was not part of this fixture and is not claimed validated.

## Error semantics

The unmodified SDK maps STATUS_LOGON_FAILURE to POSIX ECONNREFUSED. The bridge now distinguishes that **verified server status** from an actual TCP refusal. Only explicit authentication NTSTATUS values classify as a login rejection; plain ECONNREFUSED is a network error, generic EPERM stays invalidResponse. Original descriptions can contain private names and are never emitted by the default bridge diagnostics. Safe optional diagnostics include only allowlisted domain, numeric code/status and fixed reason labels.

## Validation

With the independent ResourceAccessAMSMB2 package and standard-conforming error-body fixture on 127.0.0.1:14465: 22/22 tests passed. This includes the original strict wrong-password assertion, no retry/read after rejected login, corrected-credential recovery, missing file, explicit server-denial, Unicode/spaces, exact offset bytes, EOF and lifecycle privacy/cancellation. A bound but non-listening TCP port actually timed out on this Mac; it returned timedOut with no NTSTATUS, not authentication failure. Address Sanitizer: 10/10 transport tests passed with `detect_leaks=0`; this is address checking, not a claim of leak freedom. Generic iOS unsigned library build passed. Logs and reproduction commands are in `../../ResourceAccessAMSMB2/VALIDATION.json` and `DIAGNOSTICS.md`.

These are synthetic loopback SMB2 checks, not a blanket NAS, SMB3 encryption, iPhone LAN or media playback certification. The independent iPhone probe is a separate validation step.

## License and rebuilding

Original Swift wrapper headers identify MIT; the repository-wide `LICENSE` is LGPL 2.1. `Dependencies/libsmb2/COPYING` assigns LGPL 2.1-or-later to lib/include and BSD 2-clause to examples; `LICENCE-LGPL-2.1.txt` is retained. Existing notices stay in each source. Local changes to the respective files remain under their original terms; the new Swift metadata file is MIT. Do not label the combined SDK simply MIT.

Both upstream Package manifests are retained and still declare a dynamic AMSMB2 product. The bridge uses `.package(path: "../Vendor/AMSMB2")`; no moving Git branch or binary-only dependency is required. The full source plus the independent App/project, bridge and ResourceAccess core are to accompany the test binary so a recipient can modify and rebuild/relink the library, then re-sign/install using their own Apple signing identity. Do not impose a restriction on reverse engineering for debugging modifications to this LGPL library. The App packaging step must separately verify the actual embedded dynamic framework and code signatures.

Upstream manifests mention swift-atomics solely for their own tests; it is not built by this bridge dependency graph. Impacket is a Python fixture tool, not part of this SDK or the iPhone binary.
