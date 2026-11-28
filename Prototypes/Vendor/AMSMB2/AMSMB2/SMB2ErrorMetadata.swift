// Added for Sumo's isolated resource probe, 2026-11-25.
// MIT, matching the AMSMB2 Swift wrapper. Full combined dependency terms remain
// in LICENSE and Dependencies/libsmb2/COPYING.
import Foundation

/// A verified server NTSTATUS copied before socket/context cleanup. Its absence
/// means no NTSTATUS was captured; callers must not infer one from POSIX errno.
public enum SMB2ErrorMetadata {
    public static let ntStatusKey = "AMSMB2.NTStatus"
}
