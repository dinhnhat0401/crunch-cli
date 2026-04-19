import Foundation

/// The four kinds of files Crunch can compress.
public enum FileKind: String, Sendable, CaseIterable, Hashable {
    /// Video files (MP4, MOV, M4V, and best-effort others).
    case video
    /// Still images and animated images (JPEG, PNG, HEIC, GIF, WebP, ...).
    case image
    /// PDF documents.
    case pdf
    /// Audio files (MP3, WAV, AAC, M4A, FLAC, AIFF, OGG, ...).
    case audio
}
