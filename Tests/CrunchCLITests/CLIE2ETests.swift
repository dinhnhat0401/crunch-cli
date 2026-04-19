// End-to-end tests for the `crunch` CLI binary. Each test spawns the
// built executable from .build/debug/ via Process — no mocking, no
// in-process invocation — so exit codes, stdout, stderr, and the
// CrunchCore→CLI exit-code mapping are all exercised the same way a
// shell script or CI step would hit them.

import XCTest
import AVFoundation
import CoreVideo

final class CLIE2ETests: XCTestCase {

    // MARK: - Locate the built binary

    /// Walk up from the test source file until we find a sibling
    /// `.build/debug/crunch`. Prefer the binary beside the current test
    /// bundle first so `--scratch-path` runs do not accidentally execute a
    /// stale repo-local build.
    private static var binaryURL: URL = {
        let bundleDir = Bundle(for: CLIE2ETests.self).bundleURL.deletingLastPathComponent()
        let bundledCandidate = bundleDir.appendingPathComponent("crunch")
        if FileManager.default.isExecutableFile(atPath: bundledCandidate.path) {
            return bundledCandidate
        }

        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(".build/debug/crunch")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("crunch binary not found — run `swift build` first")
    }()

    private var fixtureURL: URL {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "solid", withExtension: "jpg", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "solid", withExtension: "jpg") else {
            fatalError("missing solid.jpg fixture in CLI test bundle")
        }
        return url
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CLIE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Process runner

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    private func runCLI(_ args: [String], timeout: TimeInterval = 20.0) throws -> RunResult {
        let process = Process()
        process.executableURL = Self.binaryURL
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Read pipes on background threads so a flood doesn't deadlock on a
        // full OS pipe buffer.
        let outData = DispatchQueue.global().sync { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errData = DispatchQueue.global().sync { errPipe.fileHandleForReading.readDataToEndOfFile() }

        process.waitUntilExit()

        return RunResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private func writeTestVideo(
        to url: URL,
        size: CGSize = CGSize(width: 640, height: 360)
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "CLIE2ETests", code: 1)
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "CLIE2ETests", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "CLIE2ETests", code: 3)
        }

        for (index, time) in stride(from: 0.0, to: 1.0, by: 1.0 / 30.0).enumerated() {
            while !input.isReadyForMoreMediaData {
                await Task.yield()
            }

            let pixelBuffer = try makePixelBuffer(
                from: pool,
                width: Int(size.width),
                height: Int(size.height),
                red: UInt8((index * 37) % 255),
                green: UInt8((index * 71) % 255),
                blue: UInt8((index * 103) % 255)
            )

            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)
            ) else {
                throw writer.error ?? NSError(domain: "CLIE2ETests", code: 4)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "CLIE2ETests", code: 5)
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
            throw NSError(domain: "CLIE2ETests", code: 6)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "CLIE2ETests", code: 7)
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

    // MARK: - Happy path

    /// `crunch fixture.jpg -o out.jpg --overwrite` exits 0 and produces a
    /// non-empty JPEG at the requested path.
    func testCLICompressesJPEGWithExplicitOutput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("in.jpg")
        let output = dir.appendingPathComponent("out.jpg")
        try FileManager.default.copyItem(at: fixtureURL, to: source)

        let result = try runCLI([
            source.path, "-o", output.path,
            "--preset", "balanced", "--overwrite", "--quiet",
        ])

        XCTAssertEqual(result.exitCode, 0, "stderr:\n\(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let outputBytes = try FileManager.default
            .attributesOfItem(atPath: output.path)[.size] as? NSNumber
        XCTAssertNotNil(outputBytes)
        XCTAssertGreaterThan(outputBytes!.int64Value, 0)
    }

    /// With no `-o`, the CLI writes alongside the source with the
    /// `_crunched` suffix.
    func testCLIDefaultOutputPathUsesCrunchedSuffix() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: fixtureURL, to: source)

        let result = try runCLI([source.path, "--overwrite", "--quiet"])
        XCTAssertEqual(result.exitCode, 0, "stderr:\n\(result.stderr)")

        let expected = dir.appendingPathComponent("photo_crunched.jpg")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expected.path),
            "expected default output at \(expected.path)"
        )
    }

    func testCLICompressesVideoWithExplicitOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("clip.mp4")
        let output = dir.appendingPathComponent("clip-out.mp4")
        try await writeTestVideo(to: source)

        let result = try runCLI([
            source.path, "-o", output.path,
            "--preset", "balanced", "--overwrite", "--quiet",
        ])

        XCTAssertEqual(result.exitCode, 0, "stderr:\n\(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Error-path exit-code contract (SYSTEM-DESIGN §10.3)

    /// P2 regression: a missing source file must surface as
    /// `.sourceUnreadable` (exit 3) — **not** `.unsupportedFormat` (2) or
    /// `.compressionFailed` (4). The old behaviour routed missing-file
    /// errors through the compressor and produced exit 4, which scripts
    /// can't distinguish from a legitimate compression failure. Assert
    /// exactly 3 so the regression locks in.
    func testCLIMissingFileExits3() throws {
        let result = try runCLI(["/does/not/exist/abc.jpg", "--quiet"])
        XCTAssertEqual(
            result.exitCode, 3,
            "expected exit 3 for missing file, got \(result.exitCode); stderr:\n\(result.stderr)"
        )
    }

    /// `--preset voice fixture.jpg` → voice isn't applicable to images →
    /// exit 5.
    func testCLIVoicePresetOnImageExits5() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: fixtureURL, to: source)

        let result = try runCLI([source.path, "--preset", "voice", "--overwrite", "--quiet"])
        XCTAssertEqual(result.exitCode, 5, "stderr:\n\(result.stderr)")
        // The error message surfaces the invalid pairing.
        XCTAssertTrue(
            result.stderr.contains("voice") && result.stderr.lowercased().contains("image"),
            "expected error mentioning 'voice' and 'image' in stderr, got:\n\(result.stderr)"
        )
    }

    /// P1 regression: `crunch foo.jpg -o foo.jpg --overwrite` must exit 3
    /// and leave the source file unchanged.
    func testCLIRejectsDestinationMatchingSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: fixtureURL, to: source)

        let originalBytes = try FileManager.default
            .attributesOfItem(atPath: source.path)[.size] as? NSNumber

        let result = try runCLI([source.path, "-o", source.path, "--overwrite", "--quiet"])

        XCTAssertEqual(result.exitCode, 3, "stderr:\n\(result.stderr)")

        // Source file must still be on disk, untouched.
        let afterBytes = try FileManager.default
            .attributesOfItem(atPath: source.path)[.size] as? NSNumber
        XCTAssertEqual(
            originalBytes?.int64Value, afterBytes?.int64Value,
            "source file size changed — the guard did not hold"
        )
    }

    // MARK: - Subcommands

    /// `crunch list-presets` prints the allowedForKind matrix and exits 0.
    func testCLIListPresetsExits0AndPrintsMatrix() throws {
        let result = try runCLI(["list-presets"])
        XCTAssertEqual(result.exitCode, 0, "stderr:\n\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("balanced"))
        XCTAssertTrue(result.stdout.contains("voice"))
        XCTAssertTrue(result.stdout.contains("email-friendly") || result.stdout.contains("emailFriendly"))
    }

    /// `crunch --help` exits 0 (ArgumentParser default).
    func testCLIHelpExits0() throws {
        let result = try runCLI(["--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.isEmpty)
    }
}
