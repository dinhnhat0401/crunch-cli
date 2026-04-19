import Foundation

/// The outcome of a successful compression, delivered as the last event
/// of a `Crunch.compress(...)` stream.
public struct CompressionResult: Sendable, Hashable {
    /// The source file URL.
    public let source: URL
    /// The URL the compressed file was written to.
    public let output: URL
    /// Byte count of the source file as measured before compression.
    public let sourceBytes: Int64
    /// Byte count of the output file as written.
    public let outputBytes: Int64
    /// Wall-clock duration of the compression.
    public let duration: Duration
    /// The detected kind of the source file.
    public let kind: FileKind

    /// Create a compression result value.
    public init(
        source: URL,
        output: URL,
        sourceBytes: Int64,
        outputBytes: Int64,
        duration: Duration,
        kind: FileKind
    ) {
        self.source = source
        self.output = output
        self.sourceBytes = sourceBytes
        self.outputBytes = outputBytes
        self.duration = duration
        self.kind = kind
    }

    /// Fractional savings — `1.0 - outputBytes / sourceBytes`. Zero when
    /// the source was passed through unchanged (e.g. animated images in v1.0),
    /// and zero when `sourceBytes == 0`.
    public var savingsRatio: Double {
        guard sourceBytes > 0 else { return 0 }
        return 1.0 - Double(outputBytes) / Double(sourceBytes)
    }
}
