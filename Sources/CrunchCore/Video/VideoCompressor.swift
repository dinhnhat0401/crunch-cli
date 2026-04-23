import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox

/// Video compressor backed by `AVAssetReader` + `AVAssetWriter`.
///
/// v1.0 uses one real transcode pipeline for all shipped profiles:
/// - `highQuality` keeps the source resolution and uses a higher bitrate.
/// - `balanced` caps at 1080p with a moderate bitrate.
/// - `tiny` caps at 720p with aggressive bitrate/audio reduction.
/// - `emailFriendly` computes a target bitrate from the 25 MB contract and
///   throws `.cannotMeetSizeTarget` when the source duration exceeds the
///   loosest tier's envelope.
///
/// Audio, when present, is re-encoded to AAC alongside the video track so
/// the output remains a normal playable movie rather than a silent transcode.
struct VideoCompressor: Compressor {
    typealias KindPreset = VideoPreset

    func compress(
        source: URL,
        destination: URL,
        preset: VideoPreset,
        commonOptions: CompressionRequest.CommonOptions
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let start = ContinuousClock.now
                let tmpDir = VideoCompressor.temporaryDirectory()
                var tmpURL: URL?
                var reader: AVAssetReader?
                var writer: AVAssetWriter?

                defer {
                    if let tmpURL {
                        try? FileManager.default.removeItem(at: tmpURL)
                    }
                }

                do {
                    if FileManager.default.fileExists(atPath: destination.path)
                        && !commonOptions.overwriteExisting {
                        throw CrunchError.destinationAlreadyExists(destination)
                    }

                    let sourceBytes = try VideoCompressor.byteCount(of: source)
                    continuation.yield(.started(expectedSourceBytes: sourceBytes))
                    continuation.yield(.progress(fraction: 0.0))
                    try DiskSpaceGuard.assertSufficientSpace(
                        at: destination,
                        requiredBytes: max(sourceBytes, 64 * 1024 * 1024)
                    )

                    let container = try VideoCompressor.outputContainer(for: destination)
                    let localTmpURL = tmpDir
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(container.pathExtension)
                    tmpURL = localTmpURL

                    let asset = AVURLAsset(url: source)

                    let videoTracks: [AVAssetTrack]
                    let audioTracks: [AVAssetTrack]
                    let assetDuration: CMTime
                    let commonMetadata: [AVMetadataItem]
                    do {
                        async let videoTracksLoad = asset.loadTracks(withMediaType: .video)
                        async let audioTracksLoad = asset.loadTracks(withMediaType: .audio)
                        async let durationLoad = asset.load(.duration)
                        async let metadataLoad = asset.load(.commonMetadata)
                        videoTracks = try await videoTracksLoad
                        audioTracks = try await audioTracksLoad
                        assetDuration = try await durationLoad
                        commonMetadata = commonOptions.stripMetadata ? [] : (try await metadataLoad)
                    } catch {
                        throw CrunchError.sourceUnreadable(underlying: error)
                    }

                    guard let videoTrack = videoTracks.first else {
                        throw CrunchError.sourceUnreadable(underlying: VideoEncodeError.noVideoTrack)
                    }

                    let sourceDuration = CMTimeGetSeconds(assetDuration)
                    guard sourceDuration.isFinite, sourceDuration > 0 else {
                        throw CrunchError.sourceUnreadable(underlying: VideoEncodeError.zeroDuration)
                    }

                    let naturalSize: CGSize
                    let preferredTransform: CGAffineTransform
                    let nominalFrameRate: Float
                    do {
                        async let naturalSizeLoad = videoTrack.load(.naturalSize)
                        async let preferredTransformLoad = videoTrack.load(.preferredTransform)
                        async let frameRateLoad = videoTrack.load(.nominalFrameRate)
                        naturalSize = try await naturalSizeLoad
                        preferredTransform = try await preferredTransformLoad
                        nominalFrameRate = try await frameRateLoad
                    } catch {
                        throw CrunchError.sourceUnreadable(underlying: error)
                    }

                    let sourceSize = VideoCompressor.orientedSize(
                        naturalSize: naturalSize,
                        preferredTransform: preferredTransform
                    )

                    let sourceAudioFormat: (sampleRate: Double, channels: Int)?
                    if let audioTrack = audioTracks.first {
                        sourceAudioFormat = try await VideoCompressor.audioFormat(of: audioTrack)
                    } else {
                        sourceAudioFormat = nil
                    }

                    let sourceBitrate = try await VideoCompressor.sourceBitrate(
                        videoTrack: videoTrack,
                        audioTrack: audioTracks.first,
                        sourceBytes: sourceBytes,
                        sourceDuration: sourceDuration
                    )

                    let plan = try VideoCompressor.encodingPlan(
                        for: preset,
                        sourceSize: sourceSize,
                        sourceDuration: sourceDuration,
                        sourceAudioFormat: sourceAudioFormat,
                        sourceBitrate: sourceBitrate
                    )

                    if plan.initialProgress > 0 {
                        continuation.yield(.progress(fraction: plan.initialProgress))
                    }

                    if VideoCompressor.shouldPassthroughSource(
                        source: source,
                        destinationContainer: container,
                        sourceSize: sourceSize,
                        plan: plan,
                        sourceBitrate: sourceBitrate,
                        preset: preset,
                        commonOptions: commonOptions
                    ) {
                        try FileManager.default.copyItem(at: source, to: localTmpURL)
                        continuation.yield(.progress(fraction: 1.0))
                        try VideoCompressor.atomicallyMove(from: localTmpURL, to: destination)

                        let result = CompressionResult(
                            source: source,
                            output: destination,
                            sourceBytes: sourceBytes,
                            outputBytes: sourceBytes,
                            duration: ContinuousClock.now - start,
                            kind: .video
                        )
                        continuation.yield(.finished(result))
                        continuation.finish()
                        return
                    }

                    do {
                        reader = try AVAssetReader(asset: asset)
                    } catch {
                        throw CrunchError.sourceUnreadable(underlying: error)
                    }
                    guard let reader else {
                        throw CrunchError.sourceUnreadable(underlying: VideoEncodeError.readerStartFailed)
                    }

                    do {
                        writer = try AVAssetWriter(outputURL: localTmpURL, fileType: container.fileType)
                    } catch {
                        throw CrunchError.destinationNotWritable(localTmpURL)
                    }
                    guard let writer else {
                        throw CrunchError.destinationNotWritable(localTmpURL)
                    }

                    if !commonOptions.stripMetadata {
                        writer.metadata = commonMetadata
                    }

                    let videoComposition = VideoCompressor.videoComposition(
                        track: videoTrack,
                        sourceDuration: assetDuration,
                        naturalSize: naturalSize,
                        preferredTransform: preferredTransform,
                        targetSize: plan.targetSize,
                        nominalFrameRate: nominalFrameRate
                    )

                    let readerVideoOutput = AVAssetReaderVideoCompositionOutput(
                        videoTracks: [videoTrack],
                        videoSettings: [
                            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                        ]
                    )
                    readerVideoOutput.videoComposition = videoComposition
                    readerVideoOutput.alwaysCopiesSampleData = false
                    guard reader.canAdd(readerVideoOutput) else {
                        throw CrunchError.compressionFailed(
                            kind: .video,
                            underlying: VideoEncodeError.readerRejectedVideoOutput
                        )
                    }
                    reader.add(readerVideoOutput)

                    let resolvedVideoSettings = try VideoCompressor.videoOutputSettings(
                        writer: writer,
                        requestedCodec: preset.codec,
                        hardwareAcceleration: preset.hardwareAcceleration,
                        targetSize: plan.targetSize,
                        videoBitrate: plan.videoBitrate,
                        nominalFrameRate: nominalFrameRate
                    )

                    let writerVideoInput = AVAssetWriterInput(
                        mediaType: .video,
                        outputSettings: resolvedVideoSettings
                    )
                    writerVideoInput.expectsMediaDataInRealTime = false
                    guard writer.canAdd(writerVideoInput) else {
                        throw CrunchError.compressionFailed(
                            kind: .video,
                            underlying: VideoEncodeError.writerRejectedVideoInput
                        )
                    }
                    writer.add(writerVideoInput)

                    var readerAudioOutput: AVAssetReaderTrackOutput?
                    var writerAudioInput: AVAssetWriterInput?
                    if let audioTrack = audioTracks.first,
                       let audioFormat = sourceAudioFormat,
                       let audioBitrate = plan.audioBitrate,
                       let audioChannels = plan.audioChannels {
                        let rawAudioOutput = AVAssetReaderTrackOutput(
                            track: audioTrack,
                            outputSettings: [
                                AVFormatIDKey: kAudioFormatLinearPCM,
                                AVLinearPCMBitDepthKey: 16,
                                AVLinearPCMIsBigEndianKey: false,
                                AVLinearPCMIsFloatKey: false,
                                AVLinearPCMIsNonInterleaved: false,
                            ]
                        )
                        guard reader.canAdd(rawAudioOutput) else {
                            throw CrunchError.compressionFailed(
                                kind: .video,
                                underlying: VideoEncodeError.readerRejectedAudioOutput
                            )
                        }
                        reader.add(rawAudioOutput)
                        readerAudioOutput = rawAudioOutput

                        var audioSettings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: audioFormat.sampleRate,
                            AVEncoderBitRateKey: audioBitrate,
                            AVNumberOfChannelsKey: audioChannels,
                        ]
                        if let layout = VideoCompressor.channelLayoutData(for: audioChannels) {
                            audioSettings[AVChannelLayoutKey] = layout
                        }

                        let encodedAudioInput = AVAssetWriterInput(
                            mediaType: .audio,
                            outputSettings: audioSettings
                        )
                        encodedAudioInput.expectsMediaDataInRealTime = false
                        guard writer.canAdd(encodedAudioInput) else {
                            throw CrunchError.compressionFailed(
                                kind: .video,
                                underlying: VideoEncodeError.writerRejectedAudioInput
                            )
                        }
                        writer.add(encodedAudioInput)
                        writerAudioInput = encodedAudioInput
                    }

                    guard writer.startWriting() else {
                        let underlying = writer.error ?? VideoEncodeError.writerStartFailed
                        throw CrunchError.compressionFailed(kind: .video, underlying: underlying)
                    }
                    writer.startSession(atSourceTime: .zero)

                    guard reader.startReading() else {
                        let underlying = reader.error ?? VideoEncodeError.readerStartFailed
                        throw CrunchError.compressionFailed(kind: .video, underlying: underlying)
                    }

                    try Task.checkCancellation()

                    var lastEmittedProgress = plan.initialProgress
                    try await VideoCompressor.pumpVideo(
                        from: readerVideoOutput,
                        to: writerVideoInput,
                        sourceDuration: sourceDuration,
                        initialProgress: plan.initialProgress,
                        lastEmittedProgress: &lastEmittedProgress,
                        continuation: continuation
                    )
                    writerVideoInput.markAsFinished()

                    if reader.status == .failed {
                        let underlying = reader.error ?? VideoEncodeError.readerFailed
                        throw CrunchError.compressionFailed(kind: .video, underlying: underlying)
                    }

                    if let readerAudioOutput, let writerAudioInput {
                        try await VideoCompressor.pumpAudio(
                            from: readerAudioOutput,
                            to: writerAudioInput
                        )
                        writerAudioInput.markAsFinished()

                        if reader.status == .failed {
                            let underlying = reader.error ?? VideoEncodeError.readerFailed
                            throw CrunchError.compressionFailed(kind: .video, underlying: underlying)
                        }
                    }

                    try Task.checkCancellation()

                    await writer.finishWriting()
                    if writer.status != .completed {
                        let underlying = writer.error ?? VideoEncodeError.writerFinishFailed
                        throw CrunchError.compressionFailed(kind: .video, underlying: underlying)
                    }

                    continuation.yield(.progress(fraction: 1.0))

                    try Task.checkCancellation()

                    try VideoCompressor.atomicallyMove(from: localTmpURL, to: destination)

                    let outputBytes = try VideoCompressor.byteCount(of: destination)
                    let duration = ContinuousClock.now - start
                    let result = CompressionResult(
                        source: source,
                        output: destination,
                        sourceBytes: sourceBytes,
                        outputBytes: outputBytes,
                        duration: duration,
                        kind: .video
                    )
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch is CancellationError {
                    reader?.cancelReading()
                    writer?.cancelWriting()
                    continuation.finish(throwing: CrunchError.cancelled)
                } catch let error as CrunchError {
                    reader?.cancelReading()
                    writer?.cancelWriting()
                    continuation.finish(throwing: error)
                } catch {
                    reader?.cancelReading()
                    writer?.cancelWriting()
                    continuation.finish(
                        throwing: CrunchError.compressionFailed(kind: .video, underlying: error)
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

    // MARK: - Pump loops

    private static func pumpVideo(
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput,
        sourceDuration: TimeInterval,
        initialProgress: Double,
        lastEmittedProgress: inout Double,
        continuation: AsyncThrowingStream<CompressionEvent, Error>.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()

            if !input.isReadyForMoreMediaData {
                await Task.yield()
                continue
            }

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            if !input.append(sampleBuffer) {
                throw CrunchError.compressionFailed(
                    kind: .video,
                    underlying: VideoEncodeError.writerAppendFailed
                )
            }

            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            guard pts.isFinite, sourceDuration > 0 else { continue }

            let encodedFraction = min(max(pts / sourceDuration, 0.0), 1.0)
            let progress = initialProgress + encodedFraction * (1.0 - initialProgress)
            let clamped = min(progress, 0.99)
            if clamped - lastEmittedProgress >= 0.02 {
                lastEmittedProgress = clamped
                continuation.yield(.progress(fraction: clamped))
            }
        }
    }

    private static func pumpAudio(
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput
    ) async throws {
        while true {
            try Task.checkCancellation()

            if !input.isReadyForMoreMediaData {
                await Task.yield()
                continue
            }

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            if !input.append(sampleBuffer) {
                throw CrunchError.compressionFailed(
                    kind: .video,
                    underlying: VideoEncodeError.writerAppendFailed
                )
            }
        }
    }

    // MARK: - Planning

    private struct EncodingPlan {
        let targetSize: CGSize
        let videoBitrate: Int
        let audioBitrate: Int?
        let audioChannels: Int?
        let initialProgress: Double
    }

    private struct EmailFriendlyTier {
        let boundingBox: CGSize
        let audioKbps: Int
        let audioMono: Bool
        let videoFloorKbps: Int
    }

    private struct SourceBitrate {
        let videoBitsPerSecond: Double?
        let audioBitsPerSecond: Double?

        var totalBitsPerSecond: Double? {
            let sum = (videoBitsPerSecond ?? 0) + (audioBitsPerSecond ?? 0)
            return sum > 0 ? sum : nil
        }
    }

    private static let emailFriendlyTiers: [EmailFriendlyTier] = [
        .init(boundingBox: CGSize(width: 1920, height: 1080), audioKbps: 128, audioMono: false, videoFloorKbps: 1500),
        .init(boundingBox: CGSize(width: 1920, height: 1080), audioKbps: 128, audioMono: false, videoFloorKbps: 800),
        .init(boundingBox: CGSize(width: 1280, height: 720), audioKbps: 96, audioMono: false, videoFloorKbps: 500),
        .init(boundingBox: CGSize(width: 1280, height: 720), audioKbps: 64, audioMono: true, videoFloorKbps: 350),
        .init(boundingBox: CGSize(width: 854, height: 480), audioKbps: 64, audioMono: true, videoFloorKbps: 250),
        .init(boundingBox: CGSize(width: 854, height: 480), audioKbps: 48, audioMono: true, videoFloorKbps: 180),
    ]

    private static func encodingPlan(
        for preset: VideoPreset,
        sourceSize: CGSize,
        sourceDuration: TimeInterval,
        sourceAudioFormat: (sampleRate: Double, channels: Int)?,
        sourceBitrate: SourceBitrate?
    ) throws -> EncodingPlan {
        let hasAudio = sourceAudioFormat != nil
        let sourceChannels = sourceAudioFormat?.channels ?? 0

        switch preset.profile {
        case .highQuality:
            let targetSize = evenSize(sourceSize)
            let audioBitrate = hasAudio ? 192_000 : nil
            return EncodingPlan(
                targetSize: targetSize,
                videoBitrate: cappedVideoBitrate(
                    desiredVideoBitrate: scaledBitrate(
                        for: targetSize,
                        baseAt1080p: 10_000_000,
                        min: 4_000_000,
                        max: 16_000_000
                    ),
                    audioBitrate: audioBitrate,
                    sourceBitrate: sourceBitrate,
                    profile: .highQuality
                ),
                audioBitrate: audioBitrate,
                audioChannels: hasAudio ? max(1, min(2, sourceChannels)) : nil,
                initialProgress: 0.0
            )

        case .balanced:
            let targetSize = fittedSize(sourceSize, landscapeBoundingBox: CGSize(width: 1920, height: 1080))
            let audioBitrate = hasAudio ? 128_000 : nil
            return EncodingPlan(
                targetSize: targetSize,
                videoBitrate: cappedVideoBitrate(
                    desiredVideoBitrate: scaledBitrate(
                        for: targetSize,
                        baseAt1080p: 5_000_000,
                        min: 1_500_000,
                        max: 8_000_000
                    ),
                    audioBitrate: audioBitrate,
                    sourceBitrate: sourceBitrate,
                    profile: .balanced
                ),
                audioBitrate: audioBitrate,
                audioChannels: hasAudio ? max(1, min(2, sourceChannels)) : nil,
                initialProgress: 0.0
            )

        case .tiny:
            let targetSize = fittedSize(sourceSize, landscapeBoundingBox: CGSize(width: 1280, height: 720))
            let audioBitrate = hasAudio ? 64_000 : nil
            return EncodingPlan(
                targetSize: targetSize,
                videoBitrate: cappedVideoBitrate(
                    desiredVideoBitrate: scaledBitrate(
                        for: targetSize,
                        baseAt1080p: 1_500_000,
                        min: 500_000,
                        max: 2_000_000
                    ),
                    audioBitrate: audioBitrate,
                    sourceBitrate: sourceBitrate,
                    profile: .tiny
                ),
                audioBitrate: audioBitrate,
                audioChannels: hasAudio ? 1 : nil,
                initialProgress: 0.0
            )

        case .emailFriendly:
            let targetBytes = 25_000_000.0
            let effectiveBits = targetBytes * 0.90 * 8.0 * 0.98

            for tier in emailFriendlyTiers {
                let audioBps = hasAudio ? Double(tier.audioKbps) * 1000.0 : 0.0
                let videoBitsAvailable = effectiveBits - (audioBps * sourceDuration)
                guard videoBitsAvailable > 0 else { continue }

                let videoBps = videoBitsAvailable / sourceDuration
                if videoBps >= Double(tier.videoFloorKbps) * 1000.0 {
                    return EncodingPlan(
                        targetSize: fittedSize(sourceSize, landscapeBoundingBox: tier.boundingBox),
                        videoBitrate: cappedVideoBitrate(
                            desiredVideoBitrate: Int(videoBps.rounded(.down)),
                            audioBitrate: hasAudio ? tier.audioKbps * 1000 : nil,
                            sourceBitrate: sourceBitrate,
                            profile: .emailFriendly
                        ),
                        audioBitrate: hasAudio ? tier.audioKbps * 1000 : nil,
                        audioChannels: hasAudio ? (tier.audioMono ? 1 : max(1, min(2, sourceChannels))) : nil,
                        initialProgress: 0.1
                    )
                }
            }

            guard let loosest = emailFriendlyTiers.last else {
                throw CrunchError.compressionFailed(
                    kind: .video,
                    underlying: VideoEncodeError.invalidEmailFriendlyConfiguration
                )
            }

            let loosestTotalBps = Double(loosest.videoFloorKbps) * 1000.0
                + (hasAudio ? Double(loosest.audioKbps) * 1000.0 : 0.0)
            let maxDuration = effectiveBits / loosestTotalBps
            throw CrunchError.cannotMeetSizeTarget(
                targetBytes: Int64(targetBytes),
                sourceDuration: sourceDuration,
                maxSupportedDuration: maxDuration
            )
        }
    }

    private static func cappedVideoBitrate(
        desiredVideoBitrate: Int,
        audioBitrate: Int?,
        sourceBitrate: SourceBitrate?,
        profile: VideoPreset.Profile
    ) -> Int {
        guard let sourceTotal = sourceBitrate?.totalBitsPerSecond else {
            return desiredVideoBitrate
        }

        let audioBitsPerSecond = Double(audioBitrate ?? 0)
        let allowedTotalMultiplier: Double
        switch profile {
        case .highQuality:
            allowedTotalMultiplier = 1.02
        case .balanced:
            allowedTotalMultiplier = 0.92
        case .tiny:
            allowedTotalMultiplier = 0.72
        case .emailFriendly:
            allowedTotalMultiplier = 0.90
        }

        let allowedVideo = max(
            120_000.0,
            sourceTotal * allowedTotalMultiplier - audioBitsPerSecond
        )
        return min(desiredVideoBitrate, Int(allowedVideo.rounded(.down)))
    }

    private static func shouldPassthroughSource(
        source: URL,
        destinationContainer: OutputContainer,
        sourceSize: CGSize,
        plan: EncodingPlan,
        sourceBitrate: SourceBitrate?,
        preset: VideoPreset,
        commonOptions: CompressionRequest.CommonOptions
    ) -> Bool {
        guard !commonOptions.stripMetadata else { return false }
        guard preset.profile == .balanced || preset.profile == .highQuality else { return false }
        guard sourceSize == plan.targetSize else { return false }
        guard let sourceTotal = sourceBitrate?.totalBitsPerSecond, sourceTotal < 250_000 else { return false }
        guard let sourceContainer = try? outputContainer(for: source),
              sourceContainer.pathExtension == destinationContainer.pathExtension else {
            return false
        }
        return true
    }

    private static func scaledBitrate(
        for size: CGSize,
        baseAt1080p: Int,
        min: Int,
        max: Int
    ) -> Int {
        let referencePixels = 1920.0 * 1080.0
        let actualPixels = Double(size.width * size.height)
        let scaled = Int((Double(baseAt1080p) * Swift.max(actualPixels, 1.0) / referencePixels).rounded())
        return Swift.max(min, Swift.min(max, scaled))
    }

    // MARK: - Geometry + transforms

    private static func orientedSize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return evenSize(CGSize(width: abs(rect.width), height: abs(rect.height)))
    }

    private static func fittedSize(
        _ sourceSize: CGSize,
        landscapeBoundingBox: CGSize
    ) -> CGSize {
        let boundingBox: CGSize
        if sourceSize.width >= sourceSize.height {
            boundingBox = landscapeBoundingBox
        } else {
            boundingBox = CGSize(
                width: landscapeBoundingBox.height,
                height: landscapeBoundingBox.width
            )
        }

        let scale = min(
            1.0,
            boundingBox.width / max(sourceSize.width, 1),
            boundingBox.height / max(sourceSize.height, 1)
        )
        let fitted = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        return evenSize(fitted)
    }

    private static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: Double(evenDimension(size.width)), height: Double(evenDimension(size.height)))
    }

    private static func evenDimension(_ value: CGFloat) -> Int {
        let floored = max(2, Int(value.rounded(.down)))
        return floored.isMultiple(of: 2) ? floored : floored - 1
    }

    private static func videoComposition(
        track: AVAssetTrack,
        sourceDuration: CMTime,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        targetSize: CGSize,
        nominalFrameRate: Float
    ) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = targetSize

        let fps = nominalFrameRate > 0 ? Int32(nominalFrameRate.rounded()) : 30
        composition.frameDuration = CMTime(value: 1, timescale: max(1, fps))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: sourceDuration)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let normalize = CGAffineTransform(
            translationX: -orientedRect.origin.x,
            y: -orientedRect.origin.y
        )
        let scale = CGAffineTransform(
            scaleX: targetSize.width / max(abs(orientedRect.width), 1),
            y: targetSize.height / max(abs(orientedRect.height), 1)
        )
        let transform = preferredTransform
            .concatenating(normalize)
            .concatenating(scale)
        layer.setTransform(transform, at: .zero)

        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    // MARK: - AVFoundation settings

    private struct OutputContainer {
        let fileType: AVFileType
        let pathExtension: String
    }

    private static func outputContainer(for destination: URL) throws -> OutputContainer {
        let ext = destination.pathExtension.lowercased()
        switch ext {
        case "", "mp4":
            return OutputContainer(fileType: .mp4, pathExtension: "mp4")
        case "m4v":
            return OutputContainer(fileType: .m4v, pathExtension: "m4v")
        case "mov":
            return OutputContainer(fileType: .mov, pathExtension: "mov")
        default:
            throw CrunchError.compressionFailed(
                kind: .video,
                underlying: VideoEncodeError.unsupportedOutputContainer(ext)
            )
        }
    }

    private static func videoOutputSettings(
        writer: AVAssetWriter,
        requestedCodec: VideoPreset.Codec,
        hardwareAcceleration: Bool,
        targetSize: CGSize,
        videoBitrate: Int,
        nominalFrameRate: Float
    ) throws -> [String: Any] {
        let codecCandidates: [AVVideoCodecType] =
            requestedCodec == .hevc ? [.hevc, .h264] : [.h264]
        let hardwareCandidates: [Bool] = hardwareAcceleration ? [true, false] : [false]

        for codec in codecCandidates {
            for useHardware in hardwareCandidates {
                let settings = buildVideoSettings(
                    codec: codec,
                    useHardwareAcceleration: useHardware,
                    targetSize: targetSize,
                    videoBitrate: videoBitrate,
                    nominalFrameRate: nominalFrameRate
                )
                if writer.canApply(outputSettings: settings, forMediaType: .video) {
                    return settings
                }
            }
        }

        throw CrunchError.compressionFailed(
            kind: .video,
            underlying: VideoEncodeError.writerRejectedVideoInput
        )
    }

    private static func buildVideoSettings(
        codec: AVVideoCodecType,
        useHardwareAcceleration: Bool,
        targetSize: CGSize,
        videoBitrate: Int,
        nominalFrameRate: Float
    ) -> [String: Any] {
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoMaxKeyFrameIntervalKey: max(24, Int((nominalFrameRate > 0 ? nominalFrameRate : 30).rounded() * 2)),
        ]
        if nominalFrameRate > 0 {
            compressionProperties[AVVideoExpectedSourceFrameRateKey] = Int(nominalFrameRate.rounded())
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(targetSize.width),
            AVVideoHeightKey: Int(targetSize.height),
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]
        if useHardwareAcceleration {
            settings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ]
        }
        return settings
    }

    private static func channelLayoutData(for count: Int) -> Data? {
        var layout = AudioChannelLayout()
        switch count {
        case 1:
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        case 2:
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        default:
            return nil
        }
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    private static func audioFormat(
        of track: AVAssetTrack
    ) async throws -> (sampleRate: Double, channels: Int) {
        let formatDescriptions: [CMFormatDescription]
        do {
            formatDescriptions = try await track.load(.formatDescriptions)
        } catch {
            throw CrunchError.sourceUnreadable(underlying: error)
        }

        guard let desc = formatDescriptions.first,
              let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return (sampleRate: 44_100, channels: 2)
        }
        return (
            sampleRate: streamDesc.mSampleRate > 0 ? streamDesc.mSampleRate : 44_100,
            channels: streamDesc.mChannelsPerFrame > 0 ? Int(streamDesc.mChannelsPerFrame) : 2
        )
    }

    private static func sourceBitrate(
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        sourceBytes: Int64,
        sourceDuration: TimeInterval
    ) async throws -> SourceBitrate? {
        guard sourceDuration > 0 else { return nil }

        let videoEstimated = try? await videoTrack.load(.estimatedDataRate)
        let audioEstimated = try? await audioTrack?.load(.estimatedDataRate)

        let normalizedVideo = normalizeEstimatedDataRate(videoEstimated)
        let normalizedAudio = normalizeEstimatedDataRate(audioEstimated)
        if normalizedVideo != nil || normalizedAudio != nil {
            return SourceBitrate(
                videoBitsPerSecond: normalizedVideo,
                audioBitsPerSecond: normalizedAudio
            )
        }

        let totalFromFile = Double(sourceBytes) * 8.0 / sourceDuration
        guard totalFromFile.isFinite, totalFromFile > 0 else { return nil }
        return SourceBitrate(
            videoBitsPerSecond: totalFromFile,
            audioBitsPerSecond: nil
        )
    }

    private static func normalizeEstimatedDataRate(_ value: Float?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Double(value)
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

private enum VideoEncodeError: Error, LocalizedError {
    case noVideoTrack
    case zeroDuration
    case readerRejectedVideoOutput
    case readerRejectedAudioOutput
    case writerRejectedVideoInput
    case writerRejectedAudioInput
    case readerStartFailed
    case writerStartFailed
    case readerFailed
    case writerAppendFailed
    case writerFinishFailed
    case unsupportedOutputContainer(String)
    case invalidEmailFriendlyConfiguration

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "source file contains no video track"
        case .zeroDuration:
            return "source video has zero duration"
        case .readerRejectedVideoOutput:
            return "asset reader rejected the configured video output"
        case .readerRejectedAudioOutput:
            return "asset reader rejected the configured audio output"
        case .writerRejectedVideoInput:
            return "asset writer rejected the configured video input"
        case .writerRejectedAudioInput:
            return "asset writer rejected the configured audio input"
        case .readerStartFailed:
            return "asset reader failed to start"
        case .writerStartFailed:
            return "asset writer failed to start"
        case .readerFailed:
            return "asset reader failed while transcoding"
        case .writerAppendFailed:
            return "asset writer failed while appending media samples"
        case .writerFinishFailed:
            return "asset writer failed to finish writing"
        case .unsupportedOutputContainer(let ext):
            return "unsupported output container for video: .\(ext)"
        case .invalidEmailFriendlyConfiguration:
            return "invalid email-friendly tier configuration"
        }
    }
}
