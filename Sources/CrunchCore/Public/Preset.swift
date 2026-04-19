import Foundation

/// A kind-scoped compression preset. Each case carries the concrete
/// kind-specific preset configuration; invalid pairings (e.g. a voice
/// audio profile on a video file) are unrepresentable at the type level.
public enum Preset: Sendable, Hashable {
    /// Video compression preset.
    case video(VideoPreset)
    /// Image compression preset.
    case image(ImagePreset)
    /// PDF compression preset.
    case pdf(PDFPreset)
    /// Audio compression preset.
    case audio(AudioPreset)

    /// The `FileKind` this preset applies to.
    public var kind: FileKind {
        switch self {
        case .video: return .video
        case .image: return .image
        case .pdf:   return .pdf
        case .audio: return .audio
        }
    }
}

/// Video compression preset. Carries profile plus kind-specific knobs.
public struct VideoPreset: Sendable, Hashable {
    /// Quality profiles available for video.
    public enum Profile: Sendable, Hashable {
        /// Two-pass encode targeting ≤ 25 MB output (videos ≤ ~13 min).
        case emailFriendly
        /// Default video profile — 4–6 Mbps @ 1080p.
        case balanced
        /// 8–12 Mbps @ source resolution.
        case highQuality
        /// 1–2 Mbps @ 720p cap.
        case tiny
    }

    /// Hardware / software codec selection.
    public enum Codec: Sendable, Hashable {
        /// HEVC (H.265) — default.
        case hevc
        /// H.264 — fallback for compatibility.
        case h264
    }

    /// The selected quality profile.
    public var profile: Profile
    /// Request VideoToolbox hardware acceleration when available.
    public var hardwareAcceleration: Bool
    /// Output codec. Defaults to HEVC.
    public var codec: Codec

    /// Create a video preset with defaults suitable for most callers.
    public init(
        profile: Profile = .balanced,
        hardwareAcceleration: Bool = true,
        codec: Codec = .hevc
    ) {
        self.profile = profile
        self.hardwareAcceleration = hardwareAcceleration
        self.codec = codec
    }
}

/// Image compression preset.
public struct ImagePreset: Sendable, Hashable {
    /// Quality profiles available for still images.
    public enum Profile: Sendable, Hashable {
        /// 90% lossy quality — print / archive.
        case highQuality
        /// 75% lossy quality — web / sharing (default).
        case balanced
        /// 50% lossy quality — email / fast loading.
        case smallFile
        /// 30% lossy quality — thumbnails / previews.
        case tiny
    }

    /// Optional resize operation applied before recompression.
    public enum Resize: Sendable, Hashable {
        /// Scale both dimensions by a factor in `(0, 1]`.
        case percentage(Double)
        /// Cap the larger dimension at this pixel count, preserving aspect ratio.
        case maxDimension(Int)
    }

    /// The selected quality profile.
    public var profile: Profile
    /// Optional resize operation; `nil` preserves source dimensions.
    public var resize: Resize?

    /// Create an image preset with defaults suitable for most callers.
    public init(profile: Profile = .balanced, resize: Resize? = nil) {
        self.profile = profile
        self.resize = resize
    }
}

/// PDF compression preset.
public struct PDFPreset: Sendable, Hashable {
    /// Quality profiles available for PDF documents.
    public enum Profile: Sendable, Hashable {
        /// 150 DPI images — print-ready.
        case highQuality
        /// 100 DPI images — email / web (default).
        case balanced
        /// 72 DPI images — quick sharing.
        case smallFile
        /// Most aggressive PDFKit-backed image optimization path.
        case tiny
    }

    /// The selected quality profile.
    public var profile: Profile

    /// Create a PDF preset with defaults suitable for most callers.
    public init(profile: Profile = .balanced) {
        self.profile = profile
    }
}

/// Audio compression preset. v1.0 outputs AAC in an M4A container.
public struct AudioPreset: Sendable, Hashable {
    /// Quality profiles available for audio.
    public enum Profile: Sendable, Hashable {
        /// 256 kbps — music / podcasts.
        case highQuality
        /// 128 kbps — most use cases (default).
        case balanced
        /// 64 kbps mono — voice recordings / podcasts.
        case voice
        /// 32 kbps mono — maximum compression.
        case tiny
    }

    /// The selected quality profile.
    public var profile: Profile

    /// Create an audio preset with defaults suitable for most callers.
    public init(profile: Profile = .balanced) {
        self.profile = profile
    }
}
