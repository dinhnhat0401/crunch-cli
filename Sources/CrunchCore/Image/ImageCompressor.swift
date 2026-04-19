import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Still-image compressor implementing the static ImageIO pipeline
/// described in SYSTEM-DESIGN §9.2. Animated inputs are rejected in v1.0
/// with `.unsupportedFormat(detected: "animated-<format>")`; per-frame
/// recompression is planned for v1.1.
struct ImageCompressor: Compressor {
    typealias KindPreset = ImagePreset

    func compress(
        source: URL,
        destination: URL,
        preset: ImagePreset,
        commonOptions: CompressionRequest.CommonOptions
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let start = ContinuousClock.now
                let tmpDir = ImageCompressor.temporaryDirectory()
                let tmpURL = tmpDir.appendingPathComponent(
                    UUID().uuidString + ".tmp"
                )

                // Clean up the temp file on any exit path.
                defer {
                    try? FileManager.default.removeItem(at: tmpURL)
                }

                do {
                    // Honour overwriteExisting up front — avoid surprises.
                    if FileManager.default.fileExists(atPath: destination.path)
                        && !commonOptions.overwriteExisting {
                        throw CrunchError.destinationAlreadyExists(destination)
                    }

                    let sourceBytes = try ImageCompressor.byteCount(of: source)
                    continuation.yield(.started(expectedSourceBytes: sourceBytes))
                    continuation.yield(.progress(fraction: 0.0))

                    guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else {
                        throw CrunchError.sourceUnreadable(underlying: ImageIOError.cannotOpenSource)
                    }

                    let frameCount = CGImageSourceGetCount(src)
                    let topProps = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] ?? [:]
                    let animationFormat = ImageCompressor.animatedFormat(
                        properties: topProps,
                        frameCount: frameCount
                    )

                    try Task.checkCancellation()

                    // v1.0: reject animated inputs. Per-frame recompression is v1.1
                    // (SYSTEM-DESIGN §9.2 Option B). A silent byte-copy would
                    // ignore user-requested `resize` / `stripMetadata` / preset
                    // quality — we'd rather surface an honest error than lie
                    // about having honoured the request.
                    if let format = animationFormat {
                        throw CrunchError.unsupportedFormat(detected: "animated-\(format)")
                    }

                    try ImageCompressor.writeStatic(
                        source: src,
                        sourceURL: source,
                        tmpURL: tmpURL,
                        preset: preset,
                        commonOptions: commonOptions
                    )

                    try Task.checkCancellation()

                    // Atomic replace into destination.
                    try ImageCompressor.atomicallyMove(from: tmpURL, to: destination)

                    let outputBytes = try ImageCompressor.byteCount(of: destination)
                    let duration = ContinuousClock.now - start
                    let result = CompressionResult(
                        source: source,
                        output: destination,
                        sourceBytes: sourceBytes,
                        outputBytes: outputBytes,
                        duration: duration,
                        kind: .image
                    )
                    continuation.yield(.progress(fraction: 1.0))
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CrunchError.cancelled)
                } catch let error as CrunchError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: CrunchError.compressionFailed(kind: .image, underlying: error)
                    )
                }
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    // MARK: - Static pipeline

    private static func writeStatic(
        source: CGImageSource,
        sourceURL: URL,
        tmpURL: URL,
        preset: ImagePreset,
        commonOptions: CompressionRequest.CommonOptions
    ) throws {
        // Prefer the source type; fall back to JPEG if ImageIO can't name it.
        let typeID: CFString = CGImageSourceGetType(source) ?? (UTType.jpeg.identifier as CFString)

        guard let destination = CGImageDestinationCreateWithURL(
            tmpURL as CFURL,
            typeID,
            1,
            nil
        ) else {
            throw CrunchError.destinationNotWritable(tmpURL)
        }

        let quality = qualityValue(for: preset.profile)
        var frameProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]

        // Resize via the thumbnail API — documented memory-efficient path.
        let image: CGImage
        if let resize = preset.resize {
            let maxDim = resolveMaxDimension(resize: resize, source: source)
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw CrunchError.compressionFailed(kind: .image, underlying: ImageIOError.thumbnailFailed)
            }
            image = thumb
        } else {
            guard let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CrunchError.compressionFailed(kind: .image, underlying: ImageIOError.decodeFailed)
            }
            image = full
        }

        if !commonOptions.stripMetadata {
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                for (k, v) in props where !k.isDestinationConfigKey {
                    frameProps[k] = v
                }
            }
        }

        CGImageDestinationAddImage(destination, image, frameProps as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CrunchError.compressionFailed(kind: .image, underlying: ImageIOError.finalizeFailed)
        }
    }

    private static func qualityValue(for profile: ImagePreset.Profile) -> CGFloat {
        switch profile {
        case .highQuality: return 0.9
        case .balanced:    return 0.75
        case .smallFile:   return 0.5
        case .tiny:        return 0.3
        }
    }

    private static func resolveMaxDimension(resize: ImagePreset.Resize, source: CGImageSource) -> Int {
        switch resize {
        case .maxDimension(let px):
            return max(1, px)
        case .percentage(let factor):
            let clamped = max(0.01, min(1.0, factor))
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int else {
                return 1024
            }
            return max(1, Int(Double(max(width, height)) * clamped))
        }
    }

    // MARK: - Animated detection

    /// Returns the short format name (`"gif"`, `"apng"`, `"webp"`, `"heics"`)
    /// if the properties describe an animated image with `frameCount > 1`,
    /// otherwise `nil`. APNG rides on the PNG property dictionary — a
    /// multi-frame PNG is animated by definition.
    private static func animatedFormat(
        properties: [CFString: Any],
        frameCount: Int
    ) -> String? {
        guard frameCount > 1 else { return nil }
        if properties[kCGImagePropertyGIFDictionary] != nil { return "gif" }
        if properties[kCGImagePropertyPNGDictionary] != nil { return "apng" }
        if properties[kCGImagePropertyHEICSDictionary] != nil { return "heics" }
        if #available(macOS 14.0, *) {
            if properties[kCGImagePropertyWebPDictionary] != nil { return "webp" }
        }
        return nil
    }

    // MARK: - Filesystem helpers

    private static func temporaryDirectory() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Crunch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func byteCount(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func atomicallyMove(from tmpURL: URL, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destination.path) {
            var resulting: NSURL? = nil
            do {
                try FileManager.default.replaceItem(
                    at: destination,
                    withItemAt: tmpURL,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: &resulting
                )
            } catch {
                throw CrunchError.destinationNotWritable(destination)
            }
        } else {
            do {
                try FileManager.default.moveItem(at: tmpURL, to: destination)
            } catch {
                throw CrunchError.destinationNotWritable(destination)
            }
        }
    }
}

private enum ImageIOError: Error {
    case cannotOpenSource
    case thumbnailFailed
    case decodeFailed
    case finalizeFailed
}

private extension CFString {
    /// Property keys that describe how a destination should be written
    /// (e.g. the quality key we set ourselves) — we must not re-copy these
    /// from the source's per-frame properties.
    var isDestinationConfigKey: Bool {
        self == kCGImageDestinationLossyCompressionQuality
    }
}
