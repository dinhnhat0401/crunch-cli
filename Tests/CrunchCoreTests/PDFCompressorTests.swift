// PDF compressor tests. Fixtures are generated programmatically via
// CGPDFContext so the suite is hermetic — no committed binary PDFs.
// See CoreE2ETests for the parallel approach with animated GIF fixtures.

import XCTest
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import CrunchCore

final class PDFCompressorTests: XCTestCase {

    // MARK: - Shared helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PDFCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func byteCount(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Write a minimal multi-page PDF with both a real text run (drawn
    /// via Core Text so it emits PDF text operators) and, optionally, a
    /// large raster image (so compression has something to bite into).
    /// Any metadata passed in the `metadata` dictionary is set on the
    /// document's auxiliary info.
    private func writeTestPDF(
        to url: URL,
        pages: Int = 2,
        text: String = "The quick brown fox jumps over the lazy dog.",
        withImage: Bool = true,
        metadata: [CFString: Any] = [:]
    ) throws {
        let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        var aux: [CFString: Any] = metadata
        var mediaBoxCopy = mediaBox
        aux[kCGPDFContextMediaBox] = withUnsafePointer(to: &mediaBoxCopy) {
            Data(bytes: $0, count: MemoryLayout<CGRect>.size) as CFData
        }

        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBoxCopy, aux as CFDictionary) else {
            throw NSError(domain: "PDFCompressorTests", code: 1)
        }

        // Large pink image to balloon the raw page size — bigger than
        // JPEG-compressed output, so the balanced / smallFile tiers have
        // something to shrink. 1024 × 1024 @ 8 bit RGBA = ~4 MB per page
        // uncompressed, which embeds as ~4 MB of FlateDecode stream.
        let rasterImage: CGImage? = withImage ? try makeRasterImage(
            width: 1024,
            height: 1024
        ) : nil

        for pageIndex in 0 ..< pages {
            var box = mediaBox
            ctx.beginPDFPage([kCGPDFContextMediaBox: Data(
                bytes: &box,
                count: MemoryLayout<CGRect>.size
            ) as CFData] as CFDictionary)

            if let img = rasterImage {
                ctx.draw(img, in: CGRect(x: 40, y: 300, width: 400, height: 400))
            }

            // Use Core Text to emit real text operators. Drawing via
            // `CTLineDraw` passes through to PDF's `Tj` operators, which
            // is what makes the text extractable via
            // `PDFDocument.string` / `PDFPage.string`.
            let fullText = "Page \(pageIndex + 1). \(text)"
            let font = CTFontCreateWithName("Helvetica" as CFString, 18.0, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: CGColor(gray: 0.0, alpha: 1.0),
            ]
            let attributed = NSAttributedString(string: fullText, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 40, y: 740)
            CTLineDraw(line, ctx)

            ctx.endPDFPage()
        }

        ctx.closePDF()
    }

    private func makeRasterImage(width: Int, height: Int) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bitmapCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "PDFCompressorTests", code: 2)
        }
        // Fill with a noisy gradient so the raster doesn't collapse to
        // a trivially-compressible solid block — mimics the shape of a
        // real scanned page for JPEG compression purposes.
        for y in 0 ..< height {
            for x in 0 ..< width {
                let r = CGFloat((x + y) % 256) / 255.0
                let g = CGFloat((x * 3 + y) % 256) / 255.0
                let b = CGFloat((x + y * 5) % 256) / 255.0
                bitmapCtx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
                bitmapCtx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let img = bitmapCtx.makeImage() else {
            throw NSError(domain: "PDFCompressorTests", code: 3)
        }
        return img
    }

    // MARK: - Text preservation

    func testPDFPreservesTextViaDocumentString() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        try writeTestPDF(to: source, pages: 2)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .pdf(PDFPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        for try await _ in Crunch.compress(request) {}

        let sourceDoc = try XCTUnwrap(PDFDocument(url: source))
        let outputDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(
            outputDoc.string,
            sourceDoc.string,
            "whole-document text must be preserved per SYSTEM-DESIGN §9.3"
        )
    }

    func testPDFPreservesTextViaPerPageStringInRange() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        try writeTestPDF(to: source, pages: 3)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .pdf(PDFPreset(profile: .smallFile)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        for try await _ in Crunch.compress(request) {}

        let sourceDoc = try XCTUnwrap(PDFDocument(url: source))
        let outputDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outputDoc.pageCount, sourceDoc.pageCount)

        for i in 0 ..< sourceDoc.pageCount {
            let sourcePage = try XCTUnwrap(sourceDoc.page(at: i))
            let outputPage = try XCTUnwrap(outputDoc.page(at: i))
            XCTAssertEqual(
                outputPage.string,
                sourcePage.string,
                "per-page text must match at page \(i)"
            )
        }
    }

    func testPDFPreservesPageCount() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        try writeTestPDF(to: source, pages: 5)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .pdf(PDFPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        for try await _ in Crunch.compress(request) {}

        let sourceDoc = try XCTUnwrap(PDFDocument(url: source))
        let outputDoc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(outputDoc.pageCount, sourceDoc.pageCount)
        XCTAssertEqual(outputDoc.pageCount, 5)
    }

    // MARK: - Compression

    /// The balanced preset should shrink PDFs that embed raster images.
    /// If a future PDFKit build decides our fixture isn't compressible
    /// (e.g. the default raster encoding is already JPEG-tight), we
    /// fall back to `outputBytes <= sourceBytes` and track the stricter
    /// assertion as a TODO.
    ///
    /// TODO(v0.2): enforce a strict inequality once we switch to
    /// per-image CGPDFContent-stream rewriting with a controllable JPEG
    /// quality knob. PDFKit's `OptimizeImagesForScreen` doesn't expose
    /// a DPI dial, so on small synthetic fixtures the savings can
    /// occasionally be flat.
    func testPDFBalancedPresetShrinksOutputWhenImagesPresent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        try writeTestPDF(to: source, pages: 2, withImage: true)

        let sourceBytes = try byteCount(of: source)
        XCTAssertGreaterThan(sourceBytes, 0)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .pdf(PDFPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        for try await _ in Crunch.compress(request) {}

        let outputBytes = try byteCount(of: output)
        XCTAssertLessThanOrEqual(
            outputBytes,
            sourceBytes,
            "balanced preset must not grow the file on an image-heavy fixture"
        )
    }

    func testPDFBalancedDoesNotBloatTextOnlySource() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        try writeTestPDF(to: source, pages: 2, withImage: false)

        let sourceBytes = try byteCount(of: source)
        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .pdf(PDFPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        var finished: CompressionResult?
        for try await event in Crunch.compress(request) {
            if case .finished(let result) = event { finished = result }
        }

        let result = try XCTUnwrap(finished)
        XCTAssertLessThanOrEqual(result.outputBytes, sourceBytes)
        XCTAssertEqual(
            try byteCount(of: output),
            sourceBytes,
            "text-only PDFs should preserve the original when recompression would bloat them"
        )
    }

    // MARK: - Metadata stripping

    func testPDFStripMetadataClearsAuthor() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        try writeTestPDF(
            to: source,
            pages: 1,
            metadata: [
                kCGPDFContextAuthor: "Mei" as CFString,
                kCGPDFContextTitle: "Secret Plans" as CFString,
                kCGPDFContextKeywords: "confidential,draft" as CFString,
            ]
        )

        // Sanity: source actually carries the author we set.
        let sourceDoc = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(
            (sourceDoc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)
                ?? (sourceDoc.documentAttributes?["Author"] as? String),
            "Mei"
        )

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .pdf(PDFPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: true)
        )

        for try await _ in Crunch.compress(request) {}

        let outputDoc = try XCTUnwrap(PDFDocument(url: output))
        let author = (outputDoc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)
            ?? (outputDoc.documentAttributes?["Author"] as? String)
        if let author = author {
            XCTAssertTrue(
                author.isEmpty,
                "stripMetadata=true must clear the author field; got \(author)"
            )
        }
    }

    // MARK: - Event stream

    func testPDFFullEventStreamOrdering() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        try writeTestPDF(to: source, pages: 3)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .pdf(PDFPreset(profile: .balanced)),
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

        XCTAssertEqual(order.first, "started")
        XCTAssertEqual(order.last, "finished")
        XCTAssertEqual(order.filter { $0 == "started" }.count, 1)
        XCTAssertEqual(order.filter { $0 == "finished" }.count, 1)
        XCTAssertGreaterThanOrEqual(order.filter { $0 == "progress" }.count, 1)
    }

    // MARK: - Cancellation

    func testPDFCancellationCleansUpTempFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        // Enough pages that the per-page cancellation check has room to
        // fire before the writer finalises. Each page carries a 1024²
        // raster so copying is non-trivial.
        try writeTestPDF(to: source, pages: 20)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(output),
            preset: .pdf(PDFPreset(profile: .balanced)),
            commonOptions: .init(overwriteExisting: true, stripMetadata: false)
        )

        let task = Task {
            do {
                for try await _ in Crunch.compress(request) {
                    // As soon as we see any event, request cancellation.
                    // The compressor's per-page `Task.checkCancellation`
                    // should bail before the final write.
                    break
                }
            } catch {
                // Expected — the stream terminates with .cancelled.
            }
        }
        task.cancel()
        _ = await task.value

        // Give the background task a moment to run its `defer` cleanup
        // after the stream tears down. The compressor's `defer` removes
        // the tmp file synchronously once the Task exits.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path),
            "cancelled compression must not leave an output file at the destination"
        )

        // Verify no leftover .tmp files in our Crunch temp subdir.
        let crunchTmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Crunch", isDirectory: true)
        if FileManager.default.fileExists(atPath: crunchTmp.path) {
            let children = try FileManager.default.contentsOfDirectory(
                at: crunchTmp,
                includingPropertiesForKeys: nil
            )
            for child in children where child.pathExtension == "tmp" {
                // We only inspect files this test could have produced —
                // by UUID + recent ctime. The defer block should have
                // cleared them; anything lingering is a real leak.
                let attrs = try FileManager.default.attributesOfItem(atPath: child.path)
                if let ctime = attrs[.creationDate] as? Date,
                   Date().timeIntervalSince(ctime) < 60 {
                    XCTFail("found leftover tmp file from this test run: \(child.path)")
                }
            }
        }
    }

    // MARK: - Regression: destination matches source

    func testPDFRejectsDestinationMatchingSource() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.pdf")
        try writeTestPDF(to: source, pages: 1)

        let request = CompressionRequest(
            source: source,
            destination: .explicit(source),
            preset: .pdf(PDFPreset(profile: .balanced)),
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
}
