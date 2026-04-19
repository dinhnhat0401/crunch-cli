import Foundation

/// Kind-agnostic profile identifier used by callers (CLI, scripting) that
/// don't know a file's kind until after detection. The raw values are the
/// canonical kebab-case names accepted on the command line.
public enum ProfileName: String, CaseIterable, Sendable, Hashable {
    /// Video-only: two-pass encode targeting ≤ 25 MB.
    case emailFriendly = "email-friendly"
    /// Default profile valid for every kind.
    case balanced = "balanced"
    /// Higher-quality profile valid for every kind.
    case highQuality = "high-quality"
    /// Image + PDF only: smaller output at 50% / 72 DPI.
    case smallFile = "small-file"
    /// Audio only: 64 kbps mono voice recording profile.
    case voice = "voice"
    /// Most aggressive profile valid for every kind.
    case tiny = "tiny"

    /// The set of profiles valid for each `FileKind`.
    public static let allowedForKind: [FileKind: Set<ProfileName>] = [
        .video: [.emailFriendly, .balanced, .highQuality, .tiny],
        .image: [.highQuality, .balanced, .smallFile, .tiny],
        .pdf:   [.highQuality, .balanced, .smallFile, .tiny],
        .audio: [.highQuality, .balanced, .voice, .tiny],
    ]

    /// Resolve this kind-agnostic profile to a concrete kind-scoped `Preset`.
    /// Throws `CrunchError.presetNotApplicable` if the profile is invalid
    /// for the given kind (e.g. `--preset voice file.pdf`).
    public func resolve(for kind: FileKind) throws -> Preset {
        guard Self.allowedForKind[kind, default: []].contains(self) else {
            throw CrunchError.presetNotApplicable(profile: self, toKind: kind)
        }
        switch kind {
        case .video:
            return .video(VideoPreset(profile: videoProfile()))
        case .image:
            return .image(ImagePreset(profile: imageProfile()))
        case .pdf:
            return .pdf(PDFPreset(profile: pdfProfile()))
        case .audio:
            return .audio(AudioPreset(profile: audioProfile()))
        }
    }

    // MARK: - Internal profile mappings (kept private; callers use `resolve`)

    private func videoProfile() -> VideoPreset.Profile {
        switch self {
        case .emailFriendly: return .emailFriendly
        case .balanced:      return .balanced
        case .highQuality:   return .highQuality
        case .tiny:          return .tiny
        case .smallFile, .voice:
            // allowedForKind should have already rejected these.
            return .balanced
        }
    }

    private func imageProfile() -> ImagePreset.Profile {
        switch self {
        case .highQuality: return .highQuality
        case .balanced:    return .balanced
        case .smallFile:   return .smallFile
        case .tiny:        return .tiny
        case .emailFriendly, .voice:
            return .balanced
        }
    }

    private func pdfProfile() -> PDFPreset.Profile {
        switch self {
        case .highQuality: return .highQuality
        case .balanced:    return .balanced
        case .smallFile:   return .smallFile
        case .tiny:        return .tiny
        case .emailFriendly, .voice:
            return .balanced
        }
    }

    private func audioProfile() -> AudioPreset.Profile {
        switch self {
        case .highQuality: return .highQuality
        case .balanced:    return .balanced
        case .voice:       return .voice
        case .tiny:        return .tiny
        case .emailFriendly, .smallFile:
            return .balanced
        }
    }
}
