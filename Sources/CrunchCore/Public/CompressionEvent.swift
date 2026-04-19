import Foundation

/// Events emitted during a compression job.
///
/// The stream always begins with `.started`, yields zero or more `.progress`
/// values, and ends with exactly one `.finished` (or an error via the
/// throwing stream, or termination via `Task.cancel()`).
public enum CompressionEvent: Sendable {
    /// The compressor opened the source and measured its byte count.
    case started(expectedSourceBytes: Int64)
    /// A progress update, where `fraction` is in `0.0...1.0` of expected work.
    /// Byte counts are deliberately not reported mid-stream (see SYSTEM-DESIGN §12.3).
    case progress(fraction: Double)
    /// The compression finished successfully.
    case finished(CompressionResult)
}
