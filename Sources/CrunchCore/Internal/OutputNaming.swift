import Foundation

/// Resolves a `CompressionRequest.Destination` to a concrete file URL,
/// handling the `_crunched` suffix pattern described in the spec.
enum OutputNaming {
    /// Resolve the destination URL for a request. Does not create the file;
    /// the compressor is responsible for writing it.
    ///
    /// - `.explicit(URL)` → returned as-is.
    /// - `.alongsideSource(suffix:)` → `foo.pdf` + `"_crunched"` → `foo_crunched.pdf`
    ///   in the same directory as the source.
    static func resolve(
        _ destination: CompressionRequest.Destination,
        source: URL
    ) throws -> URL {
        switch destination {
        case .explicit(let url):
            return url
        case .alongsideSource(let suffix):
            let directory = source.deletingLastPathComponent()
            let ext = source.pathExtension
            let stem = source.deletingPathExtension().lastPathComponent
            let newStem = stem + suffix
            let candidate: URL
            if ext.isEmpty {
                candidate = directory.appendingPathComponent(newStem)
            } else {
                candidate = directory
                    .appendingPathComponent(newStem)
                    .appendingPathExtension(ext)
            }
            return candidate
        }
    }
}
