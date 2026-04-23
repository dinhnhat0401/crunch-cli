import Foundation

/// Chooses the original file over a larger recompressed output when doing so
/// still honours the caller's request. This protects the core product promise
/// that "compressed" should not surprise users by inflating files.
enum OutputPreserver {
    static func replaceWithSourceIfLarger(
        source: URL,
        candidate: URL,
        sourceBytes: Int64,
        sourceExtension: String,
        candidateExtension: String,
        stripMetadata: Bool,
        allowsPassthrough: Bool
    ) throws -> Int64 {
        guard allowsPassthrough, !stripMetadata else {
            return try byteCount(of: candidate)
        }
        guard sourceExtension.lowercased() == candidateExtension.lowercased() else {
            return try byteCount(of: candidate)
        }

        let candidateBytes = try byteCount(of: candidate)
        if candidateBytes <= sourceBytes {
            return candidateBytes
        }

        try FileManager.default.removeItem(at: candidate)
        try FileManager.default.copyItem(at: source, to: candidate)
        return sourceBytes
    }

    private static func byteCount(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
