// Using XCTest rather than Swift 5.10's Testing module for broad SwiftPM/CI
// compatibility. Migration is straightforward when Testing graduates.

import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import CrunchCore

final class ImageCompressorTests: XCTestCase {
    private var fixtureURL: URL {
        // Fixtures/ is copied as a bundle resource; locate it via the
        // test target's bundle.
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "solid", withExtension: "jpg", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "solid", withExtension: "jpg") else {
            fatalError("missing solid.jpg fixture in test bundle")
        }
        return url
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CrunchCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeJPEG(
        to url: URL,
        quality: CGFloat,
        metadata: [CFString: Any] = [:]
    ) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "ImageCompressorTests", code: 1)
        }

        for y in 0 ..< 32 {
            for x in 0 ..< 32 {
                ctx.setFillColor(
                    red: CGFloat(x) / 31.0,
                    green: CGFloat(y) / 31.0,
                    blue: CGFloat((x + y) % 8) / 7.0,
                    alpha: 1
                )
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw NSError(domain: "ImageCompressorTests", code: 2)
        }

        var props = metadata
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ImageCompressorTests", code: 3)
        }
    }

    private func imageProperties(at url: URL) throws -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw NSError(domain: "ImageCompressorTests", code: 4)
        }
        return props
    }

    func testJPEGBalancedCompression() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outputURL = tmpDir.appendingPathComponent("solid_crunched.jpg")

        let request = CompressionRequest(
            source: fixtureURL,
            destination: .explicit(outputURL),
            preset: .image(ImagePreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        var finished: CompressionResult?
        var sawStarted = false
        var sawProgress = false
        for try await event in Crunch.compress(request) {
            switch event {
            case .started: sawStarted = true
            case .progress: sawProgress = true
            case .finished(let result): finished = result
            }
        }

        XCTAssertTrue(sawStarted, "expected a .started event")
        XCTAssertTrue(sawProgress, "expected at least one .progress event")
        let result = try XCTUnwrap(finished, "expected a .finished event")

        XCTAssertGreaterThan(result.outputBytes, 0, "output file should be non-empty")
        XCTAssertLessThanOrEqual(
            result.outputBytes,
            result.sourceBytes,
            "balanced preset should not grow the file"
        )
        XCTAssertEqual(result.kind, .image)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputURL.path),
            "output file should exist on disk"
        )
    }

    func testJPEGBalancedDoesNotBloatAlreadyCompressedSource() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("in.jpg")
        let output = dir.appendingPathComponent("out.jpg")
        try writeJPEG(to: source, quality: 0.15)

        let sourceBytes = try (FileManager.default.attributesOfItem(
            atPath: source.path
        )[.size] as? NSNumber).map(\.int64Value) ?? 0

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

        let result = try XCTUnwrap(finished)
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        let outputBytes = (attrs[.size] as? NSNumber)?.int64Value
        XCTAssertLessThanOrEqual(result.outputBytes, sourceBytes)
        XCTAssertEqual(outputBytes, sourceBytes)
    }

    func testImageStripMetadataRemovesExifAndTiffFields() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("tagged.jpg")
        let output = dir.appendingPathComponent("stripped.jpg")
        try writeJPEG(
            to: source,
            quality: 0.8,
            metadata: [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFArtist: "Mei",
                ] as CFDictionary,
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: "secret",
                ] as CFDictionary,
            ]
        )

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .image(ImagePreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: true)
        )

        for try await _ in Crunch.compress(request) {}

        let props = try imageProperties(at: output)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist])
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
    }
}
