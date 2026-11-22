import Foundation

public enum CallProfileOwnerKind: String, Codable, CaseIterable, Sendable {
    case work, creator, localUser
}

public enum CallAvatarMode: String, Codable, CaseIterable, Sendable {
    case inherit, custom, none
}

public enum CallBackgroundMode: String, Codable, CaseIterable, Sendable {
    case inherit, custom, none, avatar
}

public enum CallBackgroundKind: String, Codable, CaseIterable, Sendable {
    case image, video
}

public enum CallFillMode: String, Codable, CaseIterable, Sendable {
    case black, blur
}

public enum CallFramingContentMode: String, Codable, CaseIterable, Sendable {
    case fit, fill
}

/// Framing is display metadata; the original asset is never cropped or rewritten.
/// Each use of an image keeps its own framing, including an avatar used as background.
public struct CallFraming: Codable, Equatable, Sendable {
    public var zoom: Double
    public var offsetX: Double
    public var offsetY: Double
    public var fillMode: CallFillMode
    /// Nil preserves old saved framing and lets each display choose its default:
    /// backgrounds fill the call screen; avatars and the local window fit the image.
    public var contentMode: CallFramingContentMode?
    /// Optional for backward-compatible decoding. Only static call backgrounds use this flag.
    public var spatialEffectEnabled: Bool?

    public init(zoom: Double = 1, offsetX: Double = 0, offsetY: Double = 0,
                fillMode: CallFillMode = .black, contentMode: CallFramingContentMode? = nil,
                spatialEffectEnabled: Bool? = nil) {
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.fillMode = fillMode
        self.contentMode = contentMode
        self.spatialEffectEnabled = spatialEffectEnabled
    }
}

/// Call-only appearance. These values do not replace work/creator metadata or covers.
/// Asset paths are relative to WorkAssets, and remain stored if the file is missing.
public struct CallProfile: Codable, Equatable, Sendable {
    public var roleName: String
    public var avatarMode: CallAvatarMode
    public var avatarAssetPath: String?
    public var avatarFraming: CallFraming
    public var backgroundMode: CallBackgroundMode
    public var backgroundAssetPath: String?
    public var backgroundKind: CallBackgroundKind
    public var backgroundFraming: CallFraming
    public var prefersWorkVideo: Bool

    public init(roleName: String = "", avatarMode: CallAvatarMode = .inherit,
                avatarAssetPath: String? = nil, avatarFraming: CallFraming = CallFraming(),
                backgroundMode: CallBackgroundMode = .inherit, backgroundAssetPath: String? = nil,
                backgroundKind: CallBackgroundKind = .image,
                backgroundFraming: CallFraming = CallFraming(), prefersWorkVideo: Bool = true) {
        self.roleName = roleName
        self.avatarMode = avatarMode
        self.avatarAssetPath = avatarAssetPath
        self.avatarFraming = avatarFraming
        self.backgroundMode = backgroundMode
        self.backgroundAssetPath = backgroundAssetPath
        self.backgroundKind = backgroundKind
        self.backgroundFraming = backgroundFraming
        self.prefersWorkVideo = prefersWorkVideo
    }

    public static func defaults(for ownerKind: CallProfileOwnerKind) -> CallProfile {
        switch ownerKind {
        case .work:
            return CallProfile()
        case .creator:
            return CallProfile(backgroundMode: .none)
        case .localUser:
            return CallProfile(avatarMode: .none, backgroundMode: .none)
        }
    }
}

public enum CallProfileEditingError: LocalizedError, Equatable {
    case invalidOwner, invalidPath, invalidFraming, invalidMode, missingCustomAsset, invalidStoredProfile

    public var errorDescription: String? {
        switch self {
        case .invalidOwner: return InterfaceLocalization.text("这份通话资料的作品或创作者已不存在，请重新选择。")
        case .invalidPath: return InterfaceLocalization.text("通话图片或视频路径无效，请重新选择文件。")
        case .invalidFraming: return InterfaceLocalization.text("图片取景超出有效范围，请调整后保存。")
        case .invalidMode: return InterfaceLocalization.text("这份通话资料不支持所选显示方式。")
        case .missingCustomAsset: return InterfaceLocalization.text("请选择自定通话图片或背景文件。")
        case .invalidStoredProfile: return InterfaceLocalization.text("暂时无法读取这份通话资料，原有设置已保留。")
        }
    }
}
