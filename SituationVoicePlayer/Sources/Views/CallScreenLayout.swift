import CoreGraphics

/// Shared by the inline sample-buffer renderer and the SwiftUI fallback.
enum CallScreenLayout {
    static func isLandscape(_ size: CGSize) -> Bool {
        size.width > size.height && size.width >= 560
    }

    static func avatarRect(in size: CGSize) -> CGRect {
        let landscape = isLandscape(size)
        let side = landscape
            ? min(size.width * 0.24, size.height * 0.36)
            : min(size.width * 0.5, size.height * (size.height < 650 ? 0.22 : 0.26))
        let center = CGPoint(x: size.width * (landscape ? 0.24 : 0.5),
                             y: size.height * (landscape ? 0.45 : 0.34))
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }
}
