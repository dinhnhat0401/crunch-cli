import Foundation

/// Describes one compression job: the input file, where the output goes,
/// which preset to use, and format-agnostic options.
public struct CompressionRequest: Sendable {
    /// Where to place the compressed output file.
    public enum Destination: Sendable {
        /// Write to this exact URL. Must be on a writable volume.
        case explicit(URL)
        /// Write alongside the source file using the given suffix (e.g. `"_crunched"` → `"report_crunched.pdf"`).
        case alongsideSource(suffix: String)
    }

    /// Format-agnostic knobs that apply to every kind.
    public struct CommonOptions: Sendable, Hashable {
        /// Overwrite an existing destination file instead of erroring.
        public var overwriteExisting: Bool
        /// Strip EXIF / GPS / XMP / IPTC / ID3 metadata from the output.
        public var stripMetadata: Bool

        /// Create a `CommonOptions` value.
        public init(overwriteExisting: Bool = false, stripMetadata: Bool = false) {
            self.overwriteExisting = overwriteExisting
            self.stripMetadata = stripMetadata
        }
    }

    /// The source file URL. Must point to an existing, readable file.
    public let source: URL
    /// Where to write the output file.
    public let destination: Destination
    /// The compression preset. Its `kind` must match the detected kind
    /// of `source` — otherwise `Crunch.compress` throws `.presetKindMismatch`.
    public let preset: Preset
    /// Options that apply regardless of file kind.
    public let commonOptions: CommonOptions

    /// Create a new compression request.
    public init(
        source: URL,
        destination: Destination,
        preset: Preset,
        commonOptions: CommonOptions = CommonOptions()
    ) {
        self.source = source
        self.destination = destination
        self.preset = preset
        self.commonOptions = commonOptions
    }
}
