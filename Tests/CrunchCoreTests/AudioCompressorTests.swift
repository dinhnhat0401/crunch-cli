// Tests for the AVFoundation-backed AudioCompressor (SYSTEM-DESIGN §9.4 /
// ARCHITECTURE-ENGINE §4 Audio). Fixtures are generated programmatically
// via AVAudioFile so tests are hermetic — no binary audio blobs live in
// the repo.

import XCTest
import AVFoundation
@testable import CrunchCore

final class AudioCompressorTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AudioCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a sine-wave WAV file to `url`. Defaults to 3 seconds stereo
    /// at 44.1 kHz; the duration/channel/rate knobs are there for the
    /// cancellation test that needs a longer source.
    private func writeTestWAV(
        to url: URL,
        durationSeconds: Double = 3.0,
        stereo: Bool = true,
        sampleRate: Double = 44_100
    ) throws {
        let channels: AVAudioChannelCount = stereo ? 2 : 1
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioCompressorTests", code: 1)
        }

        // 16-bit signed, interleaved on disk so the file reads as a
        // conventional WAV — not non-interleaved Float32 which is valid
        // but unusual.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let file = try AVAudioFile(forWriting: url, settings: fileSettings)

        // Generate 440 Hz sine wave in ~0.1-second chunks so we don't
        // allocate a multi-megabyte buffer at once.
        let chunkFrames = AVAudioFrameCount(sampleRate / 10)
        let totalFrames = AVAudioFrameCount(durationSeconds * sampleRate)
        let frequency = 440.0
        let twoPi = 2.0 * Double.pi
        let amplitude: Float = 0.25

        var framesWritten: AVAudioFrameCount = 0
        var phase = 0.0
        let phaseIncrement = twoPi * frequency / sampleRate

        while framesWritten < totalFrames {
            let remaining = totalFrames - framesWritten
            let frames = min(chunkFrames, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw NSError(domain: "AudioCompressorTests", code: 2)
            }
            buffer.frameLength = frames

            guard let channelData = buffer.floatChannelData else {
                throw NSError(domain: "AudioCompressorTests", code: 3)
            }
            for i in 0 ..< Int(frames) {
                let sample = Float(sin(phase)) * amplitude
                for ch in 0 ..< Int(channels) {
                    channelData[ch][i] = sample
                }
                phase += phaseIncrement
                if phase > twoPi { phase -= twoPi }
            }

            try file.write(from: buffer)
            framesWritten += frames
        }
    }

    /// Writes a WAV, then re-saves it via AVAssetExportSession with
    /// metadata attached — we can't inject metadata into a plain WAV via
    /// AVAudioFile, so we write the WAV first and produce an M4A source
    /// with artist + title tags for metadata tests.
    private func writeTestM4AWithMetadata(
        to url: URL,
        artist: String,
        title: String,
        durationSeconds: Double = 3.0
    ) async throws {
        let dir = url.deletingLastPathComponent()
        let wavURL = dir.appendingPathComponent("src-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        try writeTestWAV(to: wavURL, durationSeconds: durationSeconds, stereo: true)

        let asset = AVURLAsset(url: wavURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioCompressorTests", code: 4)
        }
        export.outputURL = url
        export.outputFileType = .m4a

        let artistItem = AVMutableMetadataItem()
        artistItem.identifier = .commonIdentifierArtist
        artistItem.value = artist as NSString
        artistItem.extendedLanguageTag = "und"

        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        titleItem.extendedLanguageTag = "und"

        export.metadata = [artistItem, titleItem]

        await export.export()
        if export.status != .completed {
            throw export.error ?? NSError(domain: "AudioCompressorTests", code: 5)
        }
    }

    // MARK: - Tests

    /// 3-second stereo WAV → M4A via the balanced preset. Output file
    /// should exist and its reported duration should land within ~100 ms
    /// of the source duration.
    func testAudioCompressesWAVToM4A() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.m4a")
        try writeTestWAV(to: source, durationSeconds: 3.0, stereo: true)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .audio(AudioPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        var finished: CompressionResult?
        for try await event in Crunch.compress(request) {
            if case .finished(let result) = event { finished = result }
        }

        XCTAssertNotNil(finished, "compression should finish")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "output should exist on disk")
        XCTAssertEqual(finished?.kind, .audio)

        let outAsset = AVURLAsset(url: output)
        let outDuration = try await outAsset.load(.duration)
        XCTAssertEqual(
            CMTimeGetSeconds(outDuration),
            3.0,
            accuracy: 0.1,
            "output duration should be within 100ms of source"
        )
    }

    /// Balanced preset on a 3-second source should produce a file
    /// substantially smaller than raw PCM — 128 kbps × 3 s ≈ 48 KB +
    /// container overhead, so < 200 KB is a loose-but-meaningful bound.
    func testAudioBalancedPresetProducesReasonableBitrate() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.m4a")
        try writeTestWAV(to: source, durationSeconds: 3.0, stereo: true)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .audio(AudioPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: true)
        )

        var finished: CompressionResult?
        for try await event in Crunch.compress(request) {
            if case .finished(let result) = event { finished = result }
        }
        let result = try XCTUnwrap(finished)

        XCTAssertGreaterThan(result.outputBytes, 0)
        XCTAssertLessThan(
            result.outputBytes,
            200_000,
            "3s at 128 kbps should be well under 200 KB, got \(result.outputBytes) bytes"
        )
        XCTAssertLessThan(
            result.outputBytes,
            result.sourceBytes,
            "AAC should be smaller than raw PCM WAV"
        )
    }

    /// Voice preset forces mono even when the source is stereo.
    func testAudioVoicePresetIsMono() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("stereo.wav")
        let output = dir.appendingPathComponent("voice.m4a")
        try writeTestWAV(to: source, durationSeconds: 3.0, stereo: true)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .audio(AudioPreset(profile: .voice)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: true)
        )

        for try await _ in Crunch.compress(request) {}

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let desc = try XCTUnwrap(formatDescriptions.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee)

        XCTAssertEqual(
            Int(asbd.mChannelsPerFrame),
            1,
            "voice preset should produce a mono output"
        )
    }

    /// Metadata (artist + title) present on the source must round-trip
    /// into the output when `stripMetadata == false`.
    func testAudioPreservesMetadata() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("tagged.m4a")
        let output = dir.appendingPathComponent("out.m4a")
        try await writeTestM4AWithMetadata(
            to: source,
            artist: "Dizzy Gillespie",
            title: "A Night in Tunisia"
        )

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .audio(AudioPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        for try await _ in Crunch.compress(request) {}

        let asset = AVURLAsset(url: output)
        let metadata = try await asset.load(.commonMetadata)

        let artistItems = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierArtist
        )
        let titleItems = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierTitle
        )

        let artistValue = try await artistItems.first?.load(.stringValue)
        let titleValue = try await titleItems.first?.load(.stringValue)

        XCTAssertEqual(artistValue, "Dizzy Gillespie")
        XCTAssertEqual(titleValue, "A Night in Tunisia")
    }

    /// `stripMetadata == true` must clear tags — output's common metadata
    /// should be empty.
    func testAudioStripMetadataRemovesTags() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("tagged.m4a")
        let output = dir.appendingPathComponent("stripped.m4a")
        try await writeTestM4AWithMetadata(
            to: source,
            artist: "Someone",
            title: "Something"
        )

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .audio(AudioPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: true)
        )

        for try await _ in Crunch.compress(request) {}

        let asset = AVURLAsset(url: output)
        let metadata = try await asset.load(.commonMetadata)
        XCTAssertTrue(
            metadata.isEmpty,
            "stripMetadata=true should produce a file with no common metadata, got \(metadata.count) items"
        )
    }

    /// Contract: exactly one `.started`, ≥1 `.progress`, exactly one
    /// `.finished`, in that order.
    func testAudioFullEventStreamOrdering() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.m4a")
        try writeTestWAV(to: source, durationSeconds: 3.0, stereo: true)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .audio(AudioPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: true)
        )

        var order: [String] = []
        for try await event in Crunch.compress(request) {
            switch event {
            case .started:  order.append("started")
            case .progress: order.append("progress")
            case .finished: order.append("finished")
            }
        }

        XCTAssertEqual(order.first, "started", "first event must be .started")
        XCTAssertEqual(order.last, "finished", "last event must be .finished")
        XCTAssertEqual(order.filter { $0 == "started" }.count, 1)
        XCTAssertEqual(order.filter { $0 == "finished" }.count, 1)
        XCTAssertGreaterThanOrEqual(order.filter { $0 == "progress" }.count, 1)
    }

    /// Cancellation mid-compression must remove the temp file and leave
    /// no output at the destination.
    func testAudioCancellationCleansUpTempFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("long.wav")
        let output = dir.appendingPathComponent("out.m4a")
        // Longer fixture so cancellation can land mid-pump.
        try writeTestWAV(to: source, durationSeconds: 10.0, stereo: true)

        // Snapshot the Crunch temp dir before the test so we can detect
        // a leftover .tmp file introduced by this run.
        let crunchTmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Crunch", isDirectory: true)
        let beforeFiles = Set(
            (try? FileManager.default.contentsOfDirectory(at: crunchTmp, includingPropertiesForKeys: nil)) ?? []
        )

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .audio(AudioPreset(profile: .highQuality)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: true)
        )

        let task = Task {
            do {
                for try await _ in Crunch.compress(request) {}
                return true
            } catch {
                return false
            }
        }

        // Let the compressor start, then cancel it.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        task.cancel()
        _ = await task.value

        // Give the defer-based cleanup a beat to run.
        try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path),
            "cancelled compression must not leave a file at the destination"
        )

        let afterFiles = Set(
            (try? FileManager.default.contentsOfDirectory(at: crunchTmp, includingPropertiesForKeys: nil)) ?? []
        )
        let leakedTmpFiles = afterFiles.subtracting(beforeFiles).filter { $0.pathExtension == "tmp" }
        XCTAssertTrue(
            leakedTmpFiles.isEmpty,
            "cancelled compression must clean up its .tmp file; leaked: \(leakedTmpFiles.map(\.lastPathComponent))"
        )
    }

    /// Regression mirroring the P1 image finding: compressing to the same
    /// path as the source must be rejected up-front.
    func testAudioRejectsDestinationMatchingSource() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("track.wav")
        try writeTestWAV(to: source, durationSeconds: 1.0, stereo: false)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(source),
            preset: .audio(AudioPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        do {
            for try await _ in Crunch.compress(request) {}
            XCTFail("expected .destinationMatchesSource")
        } catch let error as CrunchError {
            guard case .destinationMatchesSource = error else {
                return XCTFail("expected .destinationMatchesSource, got \(error)")
            }
        }
    }

    /// AVFoundation doesn't ship an MP3 encoder on macOS. Requests for the
    /// `.mp3` codec must fail fast with a clear error mentioning MP3 —
    /// never silently fall back to AAC/M4A (which would betray the caller).
    func testAudioMP3CodecRequestThrowsClearError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.mp3")
        try writeTestWAV(to: source, durationSeconds: 1.0, stereo: true)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .audio(AudioPreset(profile: .balanced, codec: .mp3)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        do {
            for try await _ in Crunch.compress(request) {}
            XCTFail("expected .compressionFailed for MP3 codec request")
        } catch let error as CrunchError {
            guard case .compressionFailed(let kind, let underlying) = error else {
                return XCTFail("expected .compressionFailed, got \(error)")
            }
            XCTAssertEqual(kind, .audio)
            let message = (underlying as NSError).localizedDescription
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("mp3"),
                "error message should mention MP3, got: \(message)"
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path),
            "no output file should be written when MP3 is rejected"
        )
    }
}
