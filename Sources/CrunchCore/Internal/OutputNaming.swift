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
        let candidate: URL
        switch destination {
        case .explicit(let url):
            candidate = url
        case .alongsideSource(let suffix):
            let directory = source.deletingLastPathComponent()
            let ext = source.pathExtension
            let stem = source.deletingPathExtension().lastPathComponent
            let newStem = stem + suffix
            if ext.isEmpty {
                candidate = directory.appendingPathComponent(newStem)
            } else {
                candidate = directory
                    .appendingPathComponent(newStem)
                    .appendingPathExtension(ext)
            }
        }

        // Reject destinations that resolve to the source file itself —
        // regardless of the `overwriteExisting` flag. Writing to the source
        // path would turn compression into destructive in-place mutation.
        if canonicalPath(of: candidate) == canonicalPath(of: source) {
            throw CrunchError.destinationMatchesSource(candidate)
        }
        return candidate
    }

    /// Canonical absolute path for comparison. Uses `standardizedFileURL` +
    /// `resolvingSymlinksInPath` so `/tmp/foo.jpg`, `/private/tmp/foo.jpg`,
    /// and `./foo.jpg` all compare equal when they point at the same file.
    private static func canonicalPath(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
