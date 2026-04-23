import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Image compressor backed by ImageIO. Static images are re-encoded as a
/// single frame; animated inputs are decoded and re-encoded frame-by-frame
/// so `resize` / metadata stripping / preset-driven quality apply to the
/// whole sequence rather than failing or silently copying bytes through.
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
                    try DiskSpaceGuard.assertSufficientSpace(
                        at: destination,
                        requiredBytes: max(sourceBytes, 8 * 1024 * 1024)
                    )

                    guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else {
                        throw CrunchError.sourceUnreadable(underlying: ImageIOError.cannotOpenSource)
                    }

                    let frameCount = CGImageSourceGetCount(src)
                    let topProps = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] ?? [:]
                    let animationFormat = ImageCompressor.animatedFormat(
                        properties: topProps,
                        frameCount: frameCount
                    )
                    let typeID = CGImageSourceGetType(src) ?? (UTType.jpeg.identifier as CFString)

                    try Task.checkCancellation()

                    if let format = animationFormat {
                        try ImageCompressor.writeAnimated(
                            source: src,
                            tmpURL: tmpURL,
                            destinationTypeID: typeID,
                            frameCount: frameCount,
                            format: format,
                            preset: preset,
                            commonOptions: commonOptions
                        ) { fraction in
                            continuation.yield(.progress(fraction: fraction))
                        }
                    } else {
                        try ImageCompressor.writeStatic(
                            source: src,
                            tmpURL: tmpURL,
                            destinationTypeID: typeID,
                            preset: preset,
                            commonOptions: commonOptions
                        )
                    }

                    try Task.checkCancellation()

                    let finalOutputBytes = try OutputPreserver.replaceWithSourceIfLarger(
                        source: source,
                        candidate: tmpURL,
                        sourceBytes: sourceBytes,
                        sourceExtension: source.pathExtension,
                        candidateExtension: source.pathExtension,
                        stripMetadata: commonOptions.stripMetadata,
                        allowsPassthrough: preset.resize == nil
                    )

                    // Atomic replace into destination.
                    try ImageCompressor.atomicallyMove(from: tmpURL, to: destination)

                    let duration = ContinuousClock.now - start
                    let result = CompressionResult(
                        source: source,
                        output: destination,
                        sourceBytes: sourceBytes,
                        outputBytes: finalOutputBytes,
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
        tmpURL: URL,
        destinationTypeID: CFString,
        preset: ImagePreset,
        commonOptions: CompressionRequest.CommonOptions
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            tmpURL as CFURL,
            destinationTypeID,
            1,
            nil
        ) else {
            throw CrunchError.destinationNotWritable(tmpURL)
        }

        let quality = qualityValue(for: preset.profile)
        var frameProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]

        let image = try decodeImage(at: 0, from: source, resize: preset.resize)

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

    private static func writeAnimated(
        source: CGImageSource,
        tmpURL: URL,
        destinationTypeID: CFString,
        frameCount: Int,
        format: AnimatedFormat,
        preset: ImagePreset,
        commonOptions: CompressionRequest.CommonOptions,
        emitProgress: (Double) -> Void
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            tmpURL as CFURL,
            destinationTypeID,
            frameCount,
            nil
        ) else {
            throw CrunchError.destinationNotWritable(tmpURL)
        }

        let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let destinationProperties = animationContainerProperties(
            from: sourceProperties,
            format: format,
            stripMetadata: commonOptions.stripMetadata
        )
        if !destinationProperties.isEmpty {
            CGImageDestinationSetProperties(destination, destinationProperties as CFDictionary)
        }

        let quality = qualityValue(for: preset.profile)
        for index in 0 ..< frameCount {
            try Task.checkCancellation()

            let image = try decodeImage(at: index, from: source, resize: preset.resize)
            let frameProps = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var destinationFrameProps = animationFrameProperties(
                from: frameProps,
                format: format,
                stripMetadata: commonOptions.stripMetadata
            )
            destinationFrameProps[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(destination, image, destinationFrameProps as CFDictionary)

            emitProgress(Double(index + 1) / Double(frameCount) * 0.95)
        }

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

    private static func resolveMaxDimension(
        resize: ImagePreset.Resize,
        source: CGImageSource,
        index: Int = 0
    ) -> Int {
        switch resize {
        case .maxDimension(let px):
            return max(1, px)
        case .percentage(let factor):
            let clamped = max(0.01, min(1.0, factor))
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int else {
                return 1024
            }
            return max(1, Int(Double(max(width, height)) * clamped))
        }
    }

    private static func decodeImage(
        at index: Int,
        from source: CGImageSource,
        resize: ImagePreset.Resize?
    ) throws -> CGImage {
        if let resize {
            let maxDim = resolveMaxDimension(
                resize: resize,
                source: source,
                index: index
            )
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(
                source,
                index,
                thumbnailOptions as CFDictionary
            ) else {
                throw CrunchError.compressionFailed(
                    kind: .image,
                    underlying: ImageIOError.thumbnailFailed
                )
            }
            return thumb
        }

        guard let full = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw CrunchError.compressionFailed(kind: .image, underlying: ImageIOError.decodeFailed)
        }
        return full
    }

    // MARK: - Animated detection

    /// Returns the animated container format if the properties describe a
    /// multi-frame image. APNG rides on the PNG property dictionary — a
    /// multi-frame PNG is animated by definition.
    private static func animatedFormat(
        properties: [CFString: Any],
        frameCount: Int
    ) -> AnimatedFormat? {
        guard frameCount > 1 else { return nil }
        if properties[kCGImagePropertyGIFDictionary] != nil { return .gif }
        if properties[kCGImagePropertyPNGDictionary] != nil { return .apng }
        if properties[kCGImagePropertyHEICSDictionary] != nil { return .heics }
        if #available(macOS 14.0, *) {
            if properties[kCGImagePropertyWebPDictionary] != nil { return .webp }
        }
        return nil
    }

    private static func animationContainerProperties(
        from properties: [CFString: Any],
        format: AnimatedFormat,
        stripMetadata: Bool
    ) -> [CFString: Any] {
        if !stripMetadata {
            return properties.filter { !$0.key.isDestinationConfigKey }
        }

        guard let sourceAnimation = properties[format.propertyDictionaryKey] as? [CFString: Any] else {
            return [:]
        }

        var animation: [CFString: Any] = [:]
        if let loopCount = sourceAnimation[format.loopCountKey] {
            animation[format.loopCountKey] = loopCount
        }
        return animation.isEmpty ? [:] : [format.propertyDictionaryKey: animation]
    }

    private static func animationFrameProperties(
        from properties: [CFString: Any],
        format: AnimatedFormat,
        stripMetadata: Bool
    ) -> [CFString: Any] {
        var result = stripMetadata ? [:] : properties.filter { !$0.key.isDestinationConfigKey }
        guard let sourceAnimation = properties[format.propertyDictionaryKey] as? [CFString: Any] else {
            return result
        }

        var animation = (result[format.propertyDictionaryKey] as? [CFString: Any]) ?? [:]
        if let delay = sourceAnimation[format.delayTimeKey] {
            animation[format.delayTimeKey] = delay
        }
        if let unclampedDelay = sourceAnimation[format.unclampedDelayTimeKey] {
            animation[format.unclampedDelayTimeKey] = unclampedDelay
        }
        if !animation.isEmpty {
            result[format.propertyDictionaryKey] = animation
        }
        return result
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

private enum AnimatedFormat {
    case gif
    case apng
    case heics
    case webp

    var propertyDictionaryKey: CFString {
        switch self {
        case .gif:
            return kCGImagePropertyGIFDictionary
        case .apng:
            return kCGImagePropertyPNGDictionary
        case .heics:
            return kCGImagePropertyHEICSDictionary
        case .webp:
            return kCGImagePropertyWebPDictionary
        }
    }

    var loopCountKey: CFString {
        switch self {
        case .gif:
            return kCGImagePropertyGIFLoopCount
        case .apng:
            return kCGImagePropertyAPNGLoopCount
        case .heics:
            return kCGImagePropertyHEICSLoopCount
        case .webp:
            return kCGImagePropertyWebPLoopCount
        }
    }

    var delayTimeKey: CFString {
        switch self {
        case .gif:
            return kCGImagePropertyGIFDelayTime
        case .apng:
            return kCGImagePropertyAPNGDelayTime
        case .heics:
            return kCGImagePropertyHEICSDelayTime
        case .webp:
            return kCGImagePropertyWebPDelayTime
        }
    }

    var unclampedDelayTimeKey: CFString {
        switch self {
        case .gif:
            return kCGImagePropertyGIFUnclampedDelayTime
        case .apng:
            return kCGImagePropertyAPNGUnclampedDelayTime
        case .heics:
            return kCGImagePropertyHEICSUnclampedDelayTime
        case .webp:
            return kCGImagePropertyWebPUnclampedDelayTime
        }
    }
}

private extension CFString {
    /// Property keys that describe how a destination should be written
    /// (e.g. the quality key we set ourselves) — we must not re-copy these
    /// from the source's per-frame properties.
    var isDestinationConfigKey: Bool {
        self == kCGImageDestinationLossyCompressionQuality
    }
}
