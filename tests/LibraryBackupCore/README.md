# Library backup regression checks

These tests use only synthetic databases and sentinel file bytes in newly created temporary directories. They never read or restore a user's device data. The target links the product's `LibraryBackupCore.swift` and `LibraryBackupLaunchGate.swift` through relative source symlinks and uses the actual Hibiki schema migrations.

Run from the repository root:

```sh
swift test --package-path tests/LibraryBackupCore --scratch-path /private/tmp/simo-library-backup-build
```

The 21 tests cover:

- A committed WAL snapshot, preferences allowlist, exclusion of secret keys/caches/upgrade backups, and byte-identical user assets after restoring into a different root.
- Current and old iOS container source roots, empty-root personal sources, `folder_rel` versus legacy absolute `folder_path`, `relative_path` playback semantics, files-as-works grouping and legacy format-folder attachments.
- Reference preservation for owned audio, covers, scripts, attachments, creator/call images and saved clips, with explicit rejection cases for missing audio, creator avatar, scanned cover/script and source attachments. The same reference validation runs during export, prepare and confirmation; an internally consistent archive that omits a referenced local file is rejected. External/NAS media remains an excluded reference.
- Added, changed or removed assets and concurrent SQLite commits during export.
- Six injected transaction failures, persistent-journal recovery after an interrupted directory swap, previous database/media/preferences preservation, and cleanup of the staged replacement after rollback or cancellation.
- Traversal, symbolic-link entries, case collisions, unexpected entries, wrong SHA-256, unsupported schema, oversized metadata and corrupt database content. A forged current schema version cannot hide missing tables.
- Actual cancellation during extraction, free-space preflight, and per-operation progress throttling before dispatch (at most 101 callbacks for one million progress samples).
- Startup interruption cleanup snapshots only existing immediate `export-UUID` / `prepared-UUID` directories, with inode/birth identity checks. Background deletion does not rescan, does not delete later operations or replacements, and preserves `Exports`, `rollback-*`, symlinks and malformed names. Any pending/journal marker—including malformed or dangling-link markers—prevents cleanup.

To generate an additional reproducible synthetic cold-launch seed, choose a new directory under `/private/tmp`:

```sh
SIMO_BACKUP_SYNTHETIC_SEED=/private/tmp/simo-backup-seed-new \
  swift test --package-path tests/LibraryBackupCore --scratch-path /private/tmp/simo-library-backup-build \
  --filter testSyntheticColdLaunchSeedContainsBothLibrariesAndValidatedPending
```

The output contains an original synthetic library, a separately validated pending replacement, the input archive and its manifest. Installing it in a dedicated test App container and cold-launching exercises `HibikiApp`'s real launch gate. Do not copy this seed to a user's installation. Its `.wav`, `.jpg` and clip payloads are sentinel bytes for preservation checks, not codec/playback fixtures.

Observed on 2026-11-28: all 21 core tests passed. A dedicated iOS Simulator App completed a real old-library → restored-library cold launch, then a second cold launch. Seven included asset files matched size/SHA-256, the owned root reanchored to the new simulator container, the restored theme appeared, and the original database remained byte-identical in `rollback-*`. No user phone was used. Subsequent stricter reference checks, rollback cleanup and progress throttling were covered by the final core suite; the parent integration task performs the final App build/UI validation.

Limits: this is not a real-device migration or low-storage/power-loss test. A synthetic interrupted filesystem state tests process-interruption recovery, not sudden device power failure. Very large libraries, background suspension and every third-party Files provider are not established by these small fixtures. Export/prepare intentionally run in the foreground. External/NAS files, permissions and Keychain secrets are not transferable. The old library is retained for rollback, so successful restoration continues to use additional disk space. The tests do not claim audio decoding, acoustic playback, or an end-to-end Files-picker interaction.
