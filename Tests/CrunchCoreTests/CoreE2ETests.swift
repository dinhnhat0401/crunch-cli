// End-to-end tests for CrunchCore's public contract. These are regression
// tests for the three Codex-P1/P2 findings against the initial scaffold —
// see the commit message that introduced this file for context.

import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import CrunchCore

final class CoreE2ETests: XCTestCase {

    // MARK: - Shared fixtures

    private var fixtureURL: URL {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "solid", withExtension: "jpg", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "solid", withExtension: "jpg") else {
            fatalError("missing solid.jpg fixture in test bundle")
        }
        return url
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CoreE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - P1 regression: destination matches source

    /// A compression request whose destination resolves to the same path as
    /// the source must throw `.destinationMatchesSource`, even when
    /// `overwriteExisting == true`. Writing to the source path would
    /// silently destroy the user's input.
    func testDestinationMatchingSourceIsRejected() async throws {
        let request = CompressionRequest(
            source: fixtureURL,
            destination: .explicit(fixtureURL),
            preset: .image(ImagePreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        do {
            for try await _ in Crunch.compress(request) {}
            XCTFail("expected .destinationMatchesSource but compression succeeded")
        } catch let error as CrunchError {
            guard case .destinationMatchesSource(let url) = error else {
                return XCTFail("expected .destinationMatchesSource, got \(error)")
            }
            XCTAssertEqual(
                url.standardizedFileURL.resolvingSymlinksInPath().path,
                fixtureURL.standardizedFileURL.resolvingSymlinksInPath().path
            )
        }
    }

    /// Symlinked and relativized paths that resolve to the source file are
    /// treated the same way — the canonicalization in OutputNaming is the
    /// load-bearing part of the guard.
    func testSymlinkedDestinationToSourceIsRejected() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: fixtureURL, to: source)
        let symlink = dir.appendingPathComponent("alias.jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(symlink),
            preset: .image(ImagePreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        do {
            for try await _ in Crunch.compress(request) {}
            XCTFail("expected .destinationMatchesSource for symlinked alias")
        } catch let error as CrunchError {
            guard case .destinationMatchesSource = error else {
                return XCTFail("expected .destinationMatchesSource, got \(error)")
            }
        }
    }

    // MARK: - P2 regression: animated images are rejected, not silently copied

    /// Animated GIFs must throw `.unsupportedFormat(detected: "animated-gif")`
    /// in v1.0 rather than silently passing bytes through — silent
    /// pass-through would ignore caller-requested `stripMetadata` / `resize`.
    func testAnimatedGIFIsRejected() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let animated = dir.appendingPathComponent("animated.gif")
        try writeTwoFrameGIF(to: animated)
        let output = dir.appendingPathComponent("out.gif")

        let request = CompressionRequest(
            source: animated,
            destination: .explicit(output),
            preset: .image(ImagePreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: true)
        )

        do {
            for try await _ in Crunch.compress(request) {}
            XCTFail("expected .unsupportedFormat for animated GIF")
        } catch let error as CrunchError {
            guard case .unsupportedFormat(let detected) = error else {
                return XCTFail("expected .unsupportedFormat, got \(error)")
            }
            XCTAssertEqual(detected, "animated-gif")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path),
            "no output file should be written when the input is rejected"
        )
    }

    /// Single-frame GIFs are treated as regular static images and compress
    /// via the normal static path.
    func testSingleFrameGIFCompressesNormally() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("still.gif")
        try writeSingleFrameGIF(to: source)
        let output = dir.appendingPathComponent("out.gif")

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .image(ImagePreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        var finished: CompressionResult?
        for try await event in Crunch.compress(request) {
            if case .finished(let result) = event { finished = result }
        }
        XCTAssertNotNil(finished, "single-frame GIF should compress successfully")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Preset kind-mismatch paths

    /// Passing a concrete kind-scoped `Preset` that doesn't match the
    /// detected file kind must throw `.presetKindMismatch`.
    func testPresetKindMismatchThrows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("out.m4a")

        let request = CompressionRequest(
            source: fixtureURL,
            destination: .explicit(output),
            preset: .audio(AudioPreset(profile: .voice)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        do {
            for try await _ in Crunch.compress(request) {}
            XCTFail("expected .presetKindMismatch")
        } catch let error as CrunchError {
            guard case .presetKindMismatch(let expected, let got) = error else {
                return XCTFail("expected .presetKindMismatch, got \(error)")
            }
            XCTAssertEqual(expected, .image)
            XCTAssertEqual(got, .audio)
        }
    }

    /// `ProfileName.resolve(for:)` must throw `.presetNotApplicable` when
    /// the profile isn't valid for the detected kind (e.g. `voice` on an
    /// image).
    func testProfileNameResolveRejectsInvalidPairing() throws {
        XCTAssertThrowsError(try ProfileName.voice.resolve(for: .image)) { error in
            guard let err = error as? CrunchError,
                  case .presetNotApplicable(let profile, let kind) = err else {
                return XCTFail("expected .presetNotApplicable, got \(error)")
            }
            XCTAssertEqual(profile, .voice)
            XCTAssertEqual(kind, .image)
        }

        // Sanity: a valid pairing resolves without throwing.
        let preset = try ProfileName.balanced.resolve(for: .image)
        guard case .image = preset else {
            return XCTFail("expected Preset.image for .balanced on .image, got \(preset)")
        }
    }

    // MARK: - Public API: Crunch.detectKind

    /// `Crunch.detectKind(at:)` must mirror the internal detector so CLI
    /// and library callers don't drift.
    func testDetectKindOnJPEG() throws {
        XCTAssertEqual(try Crunch.detectKind(at: fixtureURL), .image)
    }

    func testDetectKindOnMissingFile() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jpg")
        XCTAssertThrowsError(try Crunch.detectKind(at: missing))
    }

    // MARK: - Full event stream ordering

    /// The public contract is exactly one `.started`, zero or more
    /// `.progress`, exactly one `.finished` — in that order.
    func testFullEventStreamOrdering() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("out.jpg")

        let request = CompressionRequest(
            source: fixtureURL,
            destination: .explicit(output),
            preset: .image(ImagePreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
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

    // MARK: - Fixture helpers

    /// Write a minimal 2-frame 10×10 animated GIF via ImageIO. Used instead
    /// of committing a binary fixture so the test is hermetic and the
    /// source of the animation is inspectable.
    private func writeTwoFrameGIF(to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 2, nil
        ) else {
            throw NSError(domain: "CoreE2ETests", code: 1)
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ] as CFDictionary,
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        for i in 0 ..< 2 {
            let img = try makeSolidImage(red: i == 0 ? 1.0 : 0.0)
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: 0.1,
                ] as CFDictionary,
            ]
            CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "CoreE2ETests", code: 2)
        }
    }

    private func writeSingleFrameGIF(to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "CoreE2ETests", code: 3)
        }
        let img = try makeSolidImage(red: 0.4)
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "CoreE2ETests", code: 4)
        }
    }

    private func makeSolidImage(red: CGFloat) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 10,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "CoreE2ETests", code: 5)
        }
        ctx.setFillColor(red: red, green: 0.2, blue: 0.2, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        guard let img = ctx.makeImage() else {
            throw NSError(domain: "CoreE2ETests", code: 6)
        }
        return img
    }
}
