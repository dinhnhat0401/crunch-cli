// Using XCTest rather than Swift 5.10's Testing module for broad SwiftPM/CI
// compatibility. Migration is straightforward when Testing graduates.

import XCTest
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

    func testJPEGBalancedCompression() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CrunchCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
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
}
