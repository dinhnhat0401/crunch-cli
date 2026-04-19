// End-to-end tests for the `crunch` CLI binary. Each test spawns the
// built executable from .build/debug/ via Process — no mocking, no
// in-process invocation — so exit codes, stdout, stderr, and the
// CrunchCore→CLI exit-code mapping are all exercised the same way a
// shell script or CI step would hit them.

import XCTest

final class CLIE2ETests: XCTestCase {

    // MARK: - Locate the built binary

    /// Walk up from the test source file until we find a sibling
    /// `.build/debug/crunch`. `swift test` always builds the CLI target
    /// first because `CrunchCLITests` depends on it.
    private static var binaryURL: URL = {
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

    // MARK: - Error-path exit-code contract (SYSTEM-DESIGN §10.3)

    /// Unsupported format (missing file, no extension, empty) → exit 2 or
    /// exit 3 depending on whether detection failed at the format level
    /// (2) or at the I/O level (3). The CLI's public contract reserves both
    /// codes; we assert the code is one of them and isn't 0.
    func testCLIMissingFileExitsNonZero() throws {
        let result = try runCLI(["/does/not/exist/abc.jpg", "--quiet"])
        XCTAssertNotEqual(result.exitCode, 0)
        // Missing file typically surfaces as unsupported-format or
        // source-unreadable — both are in the expected error set.
        XCTAssertTrue(
            [2, 3].contains(result.exitCode),
            "expected exit 2 or 3 for missing file, got \(result.exitCode); stderr:\n\(result.stderr)"
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
