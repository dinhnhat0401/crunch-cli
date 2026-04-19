import Foundation

/// The only error type thrown out of `CrunchCore`. Underlying framework
/// errors are always wrapped — callers can pattern-match on cases rather
/// than inspecting opaque `NSError` codes.
public enum CrunchError: Error, Sendable {
    /// The file's detected kind isn't supported by CrunchCore.
    case unsupportedFormat(detected: String)
    /// The source file couldn't be opened or read.
    case sourceUnreadable(underlying: Error)
    /// The destination path isn't writable (permission, volume, missing parent, ...).
    case destinationNotWritable(URL)
    /// The destination already exists and `overwriteExisting` is `false`.
    case destinationAlreadyExists(URL)
    /// The resolved destination path is the same file as the source. Rejected
    /// unconditionally — even with `overwriteExisting = true` — to prevent a
    /// compression job from silently destroying its input.
    case destinationMatchesSource(URL)
    /// The destination volume doesn't have enough free space.
    case insufficientDiskSpace(needed: Int64, available: Int64)
    /// The caller passed a concrete kind-scoped `Preset` that doesn't match
    /// the detected file kind (e.g. `Preset.audio(...)` for a video file).
    case presetKindMismatch(expected: FileKind, got: FileKind)
    /// A kind-agnostic `ProfileName` couldn't be resolved for the detected
    /// kind (e.g. `--preset voice file.pdf`).
    case presetNotApplicable(profile: ProfileName, toKind: FileKind)
    /// A size-targeted preset (Email Friendly) couldn't land under its
    /// target for the given source duration. `maxSupportedDuration` is the
    /// longest source the preset can handle.
    case cannotMeetSizeTarget(
        targetBytes: Int64,
        sourceDuration: TimeInterval,
        maxSupportedDuration: TimeInterval
    )
    /// A compressor failed in a kind-specific way. The underlying error is
    /// preserved for diagnostics but should not be pattern-matched against.
    case compressionFailed(kind: FileKind, underlying: Error)
    /// The compression was cancelled via `Task.cancel()`.
    case cancelled
}

extension CrunchError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedFormat(let detected):
            return "unsupported format: \(detected)"
        case .sourceUnreadable(let underlying):
            return "source unreadable: \(underlying.localizedDescription)"
        case .destinationNotWritable(let url):
            return "destination not writable: \(url.path)"
        case .destinationAlreadyExists(let url):
            return "destination already exists: \(url.path)"
        case .destinationMatchesSource(let url):
            return "destination matches source: \(url.path) — pick a different output path"
        case .insufficientDiskSpace(let needed, let available):
            return "insufficient disk space: need \(needed), have \(available)"
        case .presetKindMismatch(let expected, let got):
            return "preset kind mismatch: file is \(expected), preset is for \(got)"
        case .presetNotApplicable(let profile, let kind):
            return "preset '\(profile.rawValue)' does not apply to \(kind.rawValue) files"
        case .cannotMeetSizeTarget(let target, let duration, let max):
            return "cannot meet size target of \(target) bytes for a \(duration)s source — max supported duration is \(max)s"
        case .compressionFailed(let kind, let underlying):
            return "\(kind.rawValue) compression failed: \(underlying.localizedDescription)"
        case .cancelled:
            return "cancelled"
        }
    }
}
