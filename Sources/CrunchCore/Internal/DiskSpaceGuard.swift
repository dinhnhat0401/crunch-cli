import Foundation

/// Best-effort early disk-space guard for compression outputs.
///
/// The compressors still rely on the underlying write APIs as the final
/// authority, but this guard upgrades the common "obviously impossible"
/// case into a deterministic `CrunchError.insufficientDiskSpace` before
/// expensive work begins.
enum DiskSpaceGuard {
    static func assertSufficientSpace(
        at destination: URL,
        requiredBytes: Int64
    ) throws {
        guard requiredBytes > 0 else { return }

        let queryURL = volumeQueryURL(for: destination)
        let values = try queryURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])

        let available = Int64(values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0))

        if available < requiredBytes {
            throw CrunchError.insufficientDiskSpace(
                needed: requiredBytes,
                available: available
            )
        }
    }

    /// Compression writes a temp file and then atomically moves it into
    /// place. Query the destination's parent so the capacity check runs
    /// against the volume that will hold the output.
    private static func volumeQueryURL(for destination: URL) -> URL {
        var candidate = destination.deletingLastPathComponent()
        while candidate.path != "/" && !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }
}
