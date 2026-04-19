import Foundation
import AVFoundation
import CoreMedia

/// Audio compressor implementing the AVFoundation pipeline described in
/// SYSTEM-DESIGN §9.4:
///
///     source → AVURLAsset → AVAssetReader (decode to LPCM)
///            → AVAssetWriter (AAC-LC) + iTunes / ID3 metadata
///            → output M4A (atomic write)
///
/// The writer's `AVAssetWriterInput` is configured with the AAC output
/// settings (`AVFormatIDKey = kAudioFormatMPEG4AAC`, bitrate, channel count)
/// so the underlying converter runs inside the writer — no separate
/// `AVAudioConverter` step is required. Channel downmix for the
/// mono-forcing `.voice` / `.tiny` profiles happens at the encoder via
/// `AVNumberOfChannelsKey: 1` plus a matching mono
/// `AVChannelLayoutKey`; the reader side still decodes the source's native
/// channel layout and hands it to the encoder as LPCM.
///
/// ## MP3 output is rejected
///
/// AVFoundation ships an MP3 *decoder* on macOS but not an MP3 *encoder* —
/// `AVAssetWriter` does not accept the MP3 file type for new files.
/// Requests with `AudioPreset.codec == .mp3` therefore throw
/// `CrunchError.compressionFailed(kind: .audio, ...)` with a message
/// surfacing this limitation, rather than silently substituting AAC/M4A.
/// The AAC/M4A default covers every supported profile.
struct AudioCompressor: Compressor {
    typealias KindPreset = AudioPreset

    func compress(
        source: URL,
        destination: URL,
        preset: AudioPreset,
        commonOptions: CompressionRequest.CommonOptions
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let start = ContinuousClock.now
                let tmpDir = AudioCompressor.temporaryDirectory()
                let tmpURL = tmpDir.appendingPathComponent(
                    UUID().uuidString + ".tmp"
                )

                // Clean up the temp file on any exit path — including
                // cancellation partway through the pump loop.
                defer {
                    try? FileManager.default.removeItem(at: tmpURL)
                }

                do {
                    // Reject MP3 encode requests up-front, before any I/O —
                    // AVFoundation can't honour them on macOS (see the
                    // type-level doc comment for why).
                    if preset.codec == .mp3 {
                        throw CrunchError.compressionFailed(
                            kind: .audio,
                            underlying: AudioEncodeError.mp3NotSupported
                        )
                    }

                    // Honour overwriteExisting up front.
                    if FileManager.default.fileExists(atPath: destination.path)
                        && !commonOptions.overwriteExisting {
                        throw CrunchError.destinationAlreadyExists(destination)
                    }

                    let sourceBytes = try AudioCompressor.byteCount(of: source)
                    continuation.yield(.started(expectedSourceBytes: sourceBytes))
                    continuation.yield(.progress(fraction: 0.0))

                    // Open source, locate the audio track.
                    let asset = AVURLAsset(url: source)
                    let audioTracks: [AVAssetTrack]
                    let assetDuration: CMTime
                    let commonMetadata: [AVMetadataItem]
                    do {
                        async let tracksLoad = asset.loadTracks(withMediaType: .audio)
                        async let durationLoad = asset.load(.duration)
                        async let metadataLoad = asset.load(.commonMetadata)
                        audioTracks = try await tracksLoad
                        assetDuration = try await durationLoad
                        commonMetadata = try await metadataLoad
                    } catch {
                        throw CrunchError.sourceUnreadable(underlying: error)
                    }
                    guard let audioTrack = audioTracks.first else {
                        throw CrunchError.sourceUnreadable(underlying: AudioEncodeError.noAudioTrack)
                    }

                    let sourceDuration = CMTimeGetSeconds(assetDuration)
                    guard sourceDuration.isFinite, sourceDuration > 0 else {
                        throw CrunchError.sourceUnreadable(underlying: AudioEncodeError.zeroDuration)
                    }

                    // Reader: decode to 16-bit LPCM at source sample rate.
                    let (sampleRate, sourceChannelCount) = try await AudioCompressor.audioFormat(of: audioTrack)

                    let reader: AVAssetReader
                    do {
                        reader = try AVAssetReader(asset: asset)
                    } catch {
                        throw CrunchError.sourceUnreadable(underlying: error)
                    }

                    let readerOutputSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                    ]
                    let readerOutput = AVAssetReaderTrackOutput(
                        track: audioTrack,
                        outputSettings: readerOutputSettings
                    )
                    guard reader.canAdd(readerOutput) else {
                        throw CrunchError.compressionFailed(
                            kind: .audio,
                            underlying: AudioEncodeError.readerRejectedOutput
                        )
                    }
                    reader.add(readerOutput)

                    // Writer: AAC in M4A to the tmp URL.
                    let writer: AVAssetWriter
                    do {
                        writer = try AVAssetWriter(outputURL: tmpURL, fileType: .m4a)
                    } catch {
                        throw CrunchError.destinationNotWritable(tmpURL)
                    }

                    let profile = preset.profile
                    let targetChannelCount = AudioCompressor.outputChannelCount(
                        profile: profile,
                        sourceChannels: sourceChannelCount
                    )
                    let bitrate = AudioCompressor.bitrate(for: profile)

                    var writerOutputSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: sampleRate,
                        AVEncoderBitRateKey: bitrate,
                        AVNumberOfChannelsKey: targetChannelCount,
                    ]
                    // Supply a matching channel layout. AAC requires one when
                    // the count isn't implicit — mono is `.Mono`, stereo is
                    // `.Stereo`. Anything else we leave for the encoder to
                    // default (we only request 1 or 2 channels in v1.0).
                    if let layout = AudioCompressor.channelLayoutData(for: targetChannelCount) {
                        writerOutputSettings[AVChannelLayoutKey] = layout
                    }

                    let writerInput = AVAssetWriterInput(
                        mediaType: .audio,
                        outputSettings: writerOutputSettings
                    )
                    writerInput.expectsMediaDataInRealTime = false

                    guard writer.canAdd(writerInput) else {
                        throw CrunchError.compressionFailed(
                            kind: .audio,
                            underlying: AudioEncodeError.writerRejectedInput
                        )
                    }
                    writer.add(writerInput)

                    if !commonOptions.stripMetadata {
                        // Copy the asset's common metadata onto the writer
                        // so artist/title/album/artwork round-trip into the
                        // output container's iTunes/ID3 box. (Writer-level
                        // metadata is asset-wide — track-level `.metadata`
                        // on the input is for per-track tags, which aren't
                        // what callers expect for audio "tags".)
                        writer.metadata = commonMetadata
                    }
                    // else: leave metadata empty — caller asked for a strip.

                    guard writer.startWriting() else {
                        let underlying = writer.error ?? AudioEncodeError.writerStartFailed
                        throw CrunchError.compressionFailed(kind: .audio, underlying: underlying)
                    }
                    writer.startSession(atSourceTime: .zero)

                    guard reader.startReading() else {
                        let underlying = reader.error ?? AudioEncodeError.readerStartFailed
                        throw CrunchError.compressionFailed(kind: .audio, underlying: underlying)
                    }

                    try Task.checkCancellation()

                    // Progress state. `lastPTS` is updated from the pump loop
                    // as each sample buffer is appended; the progress task
                    // below reads it on a ~4 Hz cadence and yields to the
                    // continuation.
                    let lastPTSBox = PTSBox()
                    let progressTask = Task { [lastPTSBox, sourceDuration] in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms ≈ 4 Hz
                            if Task.isCancelled { return }
                            let pts = await lastPTSBox.seconds
                            guard pts > 0, sourceDuration > 0 else { continue }
                            let fraction = min(max(pts / sourceDuration, 0.0), 1.0)
                            if fraction < 1.0 {
                                continuation.yield(.progress(fraction: fraction))
                            }
                        }
                    }
                    defer { progressTask.cancel() }

                    // Pump loop: reader → writer. `requestMediaDataWhenReady`
                    // would be more idiomatic for a realtime source, but
                    // here we control both sides so a tight while-loop with
                    // an `isReadyForMoreMediaData` wait is simpler and the
                    // cancellation points are explicit.
                    pump: while true {
                        try Task.checkCancellation()

                        // Backpressure — spin briefly until the writer input
                        // drains. Using Task.yield() keeps us cooperative.
                        if !writerInput.isReadyForMoreMediaData {
                            await Task.yield()
                            continue
                        }

                        guard reader.status == .reading else { break pump }
                        guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                            break pump
                        }

                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let ptsSeconds = CMTimeGetSeconds(pts)
                        if ptsSeconds.isFinite {
                            await lastPTSBox.set(ptsSeconds)
                        }

                        if !writerInput.append(sampleBuffer) {
                            let underlying = writer.error ?? AudioEncodeError.writerAppendFailed
                            throw CrunchError.compressionFailed(kind: .audio, underlying: underlying)
                        }
                    }

                    // Surface any reader failure that ended the loop.
                    if reader.status == .failed {
                        let underlying = reader.error ?? AudioEncodeError.readerFailed
                        throw CrunchError.compressionFailed(kind: .audio, underlying: underlying)
                    }

                    try Task.checkCancellation()

                    writerInput.markAsFinished()
                    await writer.finishWriting()

                    if writer.status != .completed {
                        let underlying = writer.error ?? AudioEncodeError.writerFinishFailed
                        throw CrunchError.compressionFailed(kind: .audio, underlying: underlying)
                    }

                    // Stop the progress task and emit final 1.0 before
                    // moving the file into place.
                    progressTask.cancel()
                    continuation.yield(.progress(fraction: 1.0))

                    try Task.checkCancellation()

                    // Atomic replace into destination.
                    try AudioCompressor.atomicallyMove(from: tmpURL, to: destination)

                    let outputBytes = try AudioCompressor.byteCount(of: destination)
                    let duration = ContinuousClock.now - start
                    let result = CompressionResult(
                        source: source,
                        output: destination,
                        sourceBytes: sourceBytes,
                        outputBytes: outputBytes,
                        duration: duration,
                        kind: .audio
                    )
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CrunchError.cancelled)
                } catch let error as CrunchError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: CrunchError.compressionFailed(kind: .audio, underlying: error)
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

    // MARK: - Profile → encoder settings

    private static func bitrate(for profile: AudioPreset.Profile) -> Int {
        switch profile {
        case .highQuality: return 256_000
        case .balanced:    return 128_000
        case .voice:       return 64_000
        case .tiny:        return 32_000
        }
    }

    /// Voice and tiny profiles force mono; high/balanced follow the source
    /// (but cap at 2 channels — AAC-LC in M4A is a stereo container for
    /// our purposes, we don't ship surround-sound compression in v1.0).
    private static func outputChannelCount(
        profile: AudioPreset.Profile,
        sourceChannels: Int
    ) -> Int {
        switch profile {
        case .voice, .tiny:
            return 1
        case .highQuality, .balanced:
            return max(1, min(2, sourceChannels))
        }
    }

    /// Returns a serialized `AudioChannelLayout` for the given channel
    /// count. AAC with 1 or 2 channels requires a layout tag that matches
    /// the output channel count, otherwise the encoder errors with
    /// `kAudioFormatUnsupportedPropertyError`-style failures.
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

    // MARK: - Source inspection

    /// Loads the sample rate and channel count off the track's first
    /// format description. Falls back to 44.1 kHz / stereo if the
    /// description is unreadable — any compressor-breaking details
    /// surface downstream when the reader starts.
    private static func audioFormat(of track: AVAssetTrack) async throws -> (sampleRate: Double, channels: Int) {
        let formatDescriptions: [CMFormatDescription]
        do {
            formatDescriptions = try await track.load(.formatDescriptions)
        } catch {
            throw CrunchError.sourceUnreadable(underlying: error)
        }
        guard let desc = formatDescriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return (44_100, 2)
        }
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
        let channels = Int(asbd.mChannelsPerFrame)
        return (rate, channels > 0 ? channels : 2)
    }

    // MARK: - Filesystem helpers (mirror ImageCompressor)

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

/// Actor for shared progress state. `AVAssetWriterInput.append` runs on a
/// writer-owned queue; we need a Sendable cell we can poke from the pump
/// loop and read from the throttled progress task.
private actor PTSBox {
    var seconds: Double = 0
    func set(_ value: Double) { seconds = value }
}

/// Errors surfaced when AVFoundation hands us back something we don't want
/// to re-throw directly. Wrapped inside `CrunchError.compressionFailed`
/// before leaving the module.
enum AudioEncodeError: Error, LocalizedError {
    case mp3NotSupported
    case noAudioTrack
    case zeroDuration
    case readerRejectedOutput
    case writerRejectedInput
    case readerStartFailed
    case writerStartFailed
    case readerFailed
    case writerAppendFailed
    case writerFinishFailed

    var errorDescription: String? {
        switch self {
        case .mp3NotSupported:
            return "MP3 encoding not supported by AVFoundation on macOS — use the default AAC/M4A output"
        case .noAudioTrack:
            return "source file contains no audio track"
        case .zeroDuration:
            return "source audio has zero or indeterminate duration"
        case .readerRejectedOutput:
            return "AVAssetReader rejected the requested PCM output settings"
        case .writerRejectedInput:
            return "AVAssetWriter rejected the requested AAC output settings"
        case .readerStartFailed:
            return "AVAssetReader failed to start reading"
        case .writerStartFailed:
            return "AVAssetWriter failed to start writing"
        case .readerFailed:
            return "AVAssetReader failed mid-stream"
        case .writerAppendFailed:
            return "AVAssetWriter failed to append a sample buffer"
        case .writerFinishFailed:
            return "AVAssetWriter failed to finalize the output file"
        }
    }
}
