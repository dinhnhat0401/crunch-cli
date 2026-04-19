import Foundation
import UniformTypeIdentifiers

/// Detects a file's `FileKind` from its extension (via `UTType`) with a
/// magic-number fallback for files missing or lying about their extension.
enum FileKindDetector {
    /// Detect the kind of the file at `url`. Throws `.sourceUnreadable`
    /// if the file can't be opened, or `.unsupportedFormat` if neither the
    /// UTType nor the header sniff identify a supported kind.
    static func detect(at url: URL) throws -> FileKind {
        // Step 0 — verify the file actually exists and is readable.
        // Extension-based detection is fast but doesn't touch the
        // filesystem; without this guard, a missing file with a recognised
        // extension would return a kind and the downstream compressor
        // would surface the I/O failure as `.compressionFailed` instead of
        // `.sourceUnreadable`, confusing scripts and the CLI exit-code
        // contract.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CrunchError.sourceUnreadable(
                underlying: CocoaError(.fileReadNoSuchFile, userInfo: [
                    NSFilePathErrorKey: url.path,
                ])
            )
        }

        // Step 1 — try UTType based on file extension.
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
            if let kind = kindForUTType(type) {
                return kind
            }
        }

        // Step 2 — header sniff as fallback.
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 16) ?? Data()
            if let kind = kindForHeader(header) {
                return kind
            }
            // Step 3 — not supported.
            throw CrunchError.unsupportedFormat(
                detected: url.pathExtension.isEmpty ? "<no extension>" : url.pathExtension
            )
        } catch let error as CrunchError {
            throw error
        } catch {
            throw CrunchError.sourceUnreadable(underlying: error)
        }
    }

    /// Map a declared UTType to a `FileKind`, or `nil` if unsupported.
    private static func kindForUTType(_ type: UTType) -> FileKind? {
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        if type.conforms(to: .audio) {
            return .audio
        }
        if type.conforms(to: .pdf) {
            return .pdf
        }
        if type.conforms(to: .image) {
            return .image
        }
        return nil
    }

    /// Identify a supported kind from the leading bytes of a file.
    /// Returns `nil` when no known signature matches.
    private static func kindForHeader(_ header: Data) -> FileKind? {
        guard header.count >= 4 else { return nil }
        let bytes = [UInt8](header)

        // PDF: "%PDF"
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }

        // JPEG: FF D8 FF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }

        // PNG: 89 50 4E 47
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image }

        // GIF: "GIF8"
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .image }

        // BMP: "BM"
        if bytes.starts(with: [0x42, 0x4D]) { return .image }

        // TIFF: II*\0 or MM\0*
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) { return .image }
        if bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .image }

        // RIFF containers (WAV / WebP / AVI): "RIFF" ... 4-byte size ... form type
        if bytes.count >= 12 && bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) {
            let form = Array(bytes[8..<12])
            if form == [0x57, 0x41, 0x56, 0x45] { return .audio }   // WAVE
            if form == [0x57, 0x45, 0x42, 0x50] { return .image }   // WEBP
            if form == [0x41, 0x56, 0x49, 0x20] { return .video }   // AVI
        }

        // ID3 (MP3 with tag): "ID3"
        if bytes.starts(with: [0x49, 0x44, 0x33]) { return .audio }

        // MP3 frame sync (no ID3): FF Ex / FF Fx
        if bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 {
            return .audio
        }

        // ISO BMFF (MP4 / MOV / M4A / HEIC): bytes 4..8 == "ftyp"
        if bytes.count >= 12 && Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = Array(bytes[8..<12])
            // HEIC brand → image
            if brand == [0x68, 0x65, 0x69, 0x63]   // heic
                || brand == [0x68, 0x65, 0x69, 0x78]   // heix
                || brand == [0x6D, 0x69, 0x66, 0x31] { // mif1
                return .image
            }
            // M4A brand → audio
            if brand == [0x4D, 0x34, 0x41, 0x20] { // "M4A "
                return .audio
            }
            // Default ISO BMFF → video (mp4, mov, m4v, ...)
            return .video
        }

        // FLAC
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return .audio }

        // OGG
        if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return .audio }

        return nil
    }
}
