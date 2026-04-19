import XCTest
import AVFoundation
import CoreVideo
@testable import CrunchCore

final class VideoCompressorTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VideoCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a tiny synthetic MP4/MOV with solid-color frames. The
    /// `frameTimes` hook lets us create long-duration sparse fixtures
    /// cheaply for Email Friendly tests.
    private func writeTestVideo(
        to url: URL,
        size: CGSize = CGSize(width: 640, height: 360),
        bitrate: Int = 8_000_000,
        frameTimes: [Double]? = nil
    ) async throws {
        let ext = url.pathExtension.lowercased()
        let fileType: AVFileType = (ext == "mov") ? .mov : .mp4

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "VideoCompressorTests", code: 1)
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "VideoCompressorTests", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        let resolvedFrameTimes = frameTimes ?? stride(from: 0.0, to: 2.0, by: 1.0 / 30.0).map { $0 }
        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "VideoCompressorTests", code: 3)
        }

        for (index, time) in resolvedFrameTimes.enumerated() {
            while !input.isReadyForMoreMediaData {
                await Task.yield()
            }

            let pixelBuffer = try makePixelBuffer(
                from: pool,
                width: Int(size.width),
                height: Int(size.height),
                red: UInt8((index * 53) % 255),
                green: UInt8((index * 97) % 255),
                blue: UInt8((index * 149) % 255)
            )

            let pts = CMTime(seconds: time, preferredTimescale: 600)
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw writer.error ?? NSError(domain: "VideoCompressorTests", code: 4)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "VideoCompressorTests", code: 5)
        }
    }

    private func writeTestWAV(
        to url: URL,
        durationSeconds: Double = 1.0
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "VideoCompressorTests", code: 8)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )

        let totalFrames = AVAudioFrameCount(durationSeconds * 44_100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw NSError(domain: "VideoCompressorTests", code: 9)
        }
        buffer.frameLength = totalFrames

        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "VideoCompressorTests", code: 10)
        }
        let amplitude: Float = 0.2
        let increment = (2.0 * Float.pi * 440.0) / 44_100.0
        var phase: Float = 0
        for i in 0 ..< Int(totalFrames) {
            channel[i] = sin(phase) * amplitude
            phase += increment
        }

        try file.write(from: buffer)
    }

    private func writeTestM4A(
        to url: URL,
        durationSeconds: Double = 1.0
    ) async throws {
        let wavURL = url.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        try writeTestWAV(to: wavURL, durationSeconds: durationSeconds)

        let asset = AVURLAsset(url: wavURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "VideoCompressorTests", code: 11)
        }
        export.outputURL = url
        export.outputFileType = .m4a
        await export.export()
        if export.status != .completed {
            throw export.error ?? NSError(domain: "VideoCompressorTests", code: 12)
        }
    }

    private func writeTestVideoWithAudio(
        to url: URL,
        durationSeconds: Double = 1.0
    ) async throws {
        let dir = url.deletingLastPathComponent()
        let silentURL = dir.appendingPathComponent("silent-\(UUID().uuidString).mp4")
        let audioURL = dir.appendingPathComponent("audio-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: silentURL)
            try? FileManager.default.removeItem(at: audioURL)
        }

        let frameTimes = stride(from: 0.0, to: durationSeconds, by: 1.0 / 30.0).map { $0 }
        try await writeTestVideo(to: silentURL, frameTimes: frameTimes)
        try await writeTestM4A(to: audioURL, durationSeconds: durationSeconds)

        let videoAsset = AVURLAsset(url: silentURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "VideoCompressorTests", code: 13)
        }
        guard let compAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "VideoCompressorTests", code: 14)
        }

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first,
              let audioTrack = audioTracks.first else {
            throw NSError(domain: "VideoCompressorTests", code: 15)
        }
        let duration = try await videoAsset.load(.duration)
        try compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try compAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "VideoCompressorTests", code: 16)
        }
        export.outputURL = url
        export.outputFileType = .mp4
        await export.export()
        if export.status != .completed {
            throw export.error ?? NSError(domain: "VideoCompressorTests", code: 17)
        }
    }

    private func makePixelBuffer(
        from pool: CVPixelBufferPool,
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "VideoCompressorTests", code: 6)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "VideoCompressorTests", code: 7)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< height {
            let row = ptr.advanced(by: y * bytesPerRow)
            for x in 0 ..< width {
                let offset = x * 4
                row[offset + 0] = blue
                row[offset + 1] = green
                row[offset + 2] = red
                row[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    func testVideoBalancedCompressionProducesPlayableOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.mp4")
        let output = dir.appendingPathComponent("out.mp4")
        try await writeTestVideo(to: source)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .video(VideoPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        var finished: CompressionResult?
        for try await event in Crunch.compress(request) {
            if case .finished(let result) = event { finished = result }
        }

        let result = try XCTUnwrap(finished)
        XCTAssertEqual(result.kind, .video)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertGreaterThan(result.outputBytes, 0)

        let outAsset = AVURLAsset(url: output)
        let tracks = try await outAsset.loadTracks(withMediaType: .video)
        let duration = try await outAsset.load(.duration)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
    }

    func testVideoEmailFriendlyProducesUnder25MBForShortSource() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.mp4")
        let output = dir.appendingPathComponent("out.mp4")
        try await writeTestVideo(
            to: source,
            frameTimes: [0.0, 180.0]
        )

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .video(VideoPreset(profile: .emailFriendly)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        var finished: CompressionResult?
        for try await event in Crunch.compress(request) {
            if case .finished(let result) = event { finished = result }
        }

        let result = try XCTUnwrap(finished)
        XCTAssertLessThan(result.outputBytes, 25_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testVideoEmailFriendlyRejectsTooLongSource() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.mp4")
        let output = dir.appendingPathComponent("out.mp4")
        try await writeTestVideo(
            to: source,
            frameTimes: [0.0, 1_200.0]
        )

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .video(VideoPreset(profile: .emailFriendly)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        do {
            for try await _ in Crunch.compress(request) {}
            XCTFail("expected .cannotMeetSizeTarget for a long source")
        } catch let error as CrunchError {
            guard case .cannotMeetSizeTarget(let targetBytes, let sourceDuration, let maxSupported) = error else {
                return XCTFail("expected .cannotMeetSizeTarget, got \(error)")
            }
            XCTAssertEqual(targetBytes, 25_000_000)
            XCTAssertGreaterThan(sourceDuration, maxSupported)
            XCTAssertGreaterThan(maxSupported, 0)
        }
    }

    func testVideoBalancedPreservesAudioTrackWhenPresent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.mp4")
        let output = dir.appendingPathComponent("out.mp4")
        try await writeTestVideoWithAudio(to: source, durationSeconds: 1.0)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .video(VideoPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        for try await _ in Crunch.compress(request) {}

        let outAsset = AVURLAsset(url: output)
        let audioTracks = try await outAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }

    func testVideoFullEventStreamOrdering() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.mp4")
        let output = dir.appendingPathComponent("out.mp4")
        try await writeTestVideo(to: source, frameTimes: stride(from: 0.0, to: 1.0, by: 1.0 / 30.0).map { $0 })

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .video(VideoPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        var order: [String] = []
        for try await event in Crunch.compress(request) {
            switch event {
            case .started: order.append("started")
            case .progress: order.append("progress")
            case .finished: order.append("finished")
            }
        }

        XCTAssertEqual(order.first, "started")
        XCTAssertEqual(order.last, "finished")
        XCTAssertEqual(order.filter { $0 == "started" }.count, 1)
        XCTAssertEqual(order.filter { $0 == "finished" }.count, 1)
        XCTAssertGreaterThanOrEqual(order.filter { $0 == "progress" }.count, 1)
    }
}
