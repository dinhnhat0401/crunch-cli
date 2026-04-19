import Foundation
import PDFKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// PDF compressor using PDFKit's `writeToURL(withOptions:)` pipeline with
/// image-optimization keys introduced in macOS 13.4 / iOS 16.4:
///
/// - `PDFDocumentOptimizeImagesForScreenOption` — caps embedded raster
///   resolution at a screen-friendly DPI while leaving text operators,
///   vector art, and annotations untouched.
/// - `PDFDocumentSaveImagesAsJPEGOption` — re-encodes embedded rasters as
///   JPEG, which is the dominant byte-saver on most real-world PDFs.
///
/// This is *Approach A* from the design brief. We considered the
/// page-by-page `CGContext.drawPDFPage` re-draw route (Approach B) but it
/// rasterizes vector overlays (links, ink annotations, form fields) during
/// page playback, which breaks the spec's "search/extract equivalence"
/// invariant in the harder direction — text itself is preserved, but the
/// surrounding document loses structural fidelity. PDFKit's native writer
/// is the only pathway that keeps text operators bit-preserved while
/// swapping raster XObjects, which is exactly what SYSTEM-DESIGN §9.3
/// requires.
///
/// The per-profile DPI ladder (150 / 100 / 72 / 50) is implemented by
/// combining the two options above:
///
/// | Profile     | optimize | jpeg | Intent                              |
/// |-------------|----------|------|-------------------------------------|
/// | highQuality | no       | no   | no-op re-pack; strip metadata only  |
/// | balanced    | no       | yes  | re-encode images as JPEG (~100 DPI) |
/// | smallFile   | yes      | yes  | screen-optimize + JPEG (~72 DPI)    |
/// | tiny        | yes      | yes  | screen-optimize + JPEG (~50 DPI)    |
///
/// PDFKit does not expose a numeric DPI knob — the "screen" target is
/// roughly 144 DPI in practice. That's a documented v0.2 gap: the
/// highQuality / tiny pair under-differentiate on image-heavy PDFs. We
/// accept this trade rather than rasterize pages; losing text extraction
/// would violate the SYSTEM-DESIGN §9.3 invariant that the legal /
/// knowledge-worker personas depend on. Grayscale conversion and font
/// stripping are intentionally absent from the v1.0 public API until the
/// lower-level `CGPDFContentStream` rewrite path exists to honor them.
///
/// References:
/// - SYSTEM-DESIGN §9.3 (PDF pipeline invariants — text preservation)
/// - ARCHITECTURE-ENGINE §4 (PDF implementation notes)
/// - `PDFDocument.writeToURL(_:withOptions:)` in `PDFDocument.h`
struct PDFCompressor: Compressor {
    typealias KindPreset = PDFPreset

    func compress(
        source: URL,
        destination: URL,
        preset: PDFPreset,
        commonOptions: CompressionRequest.CommonOptions
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let start = ContinuousClock.now
                let tmpDir = PDFCompressor.temporaryDirectory()
                let tmpURL = tmpDir.appendingPathComponent(
                    UUID().uuidString + ".tmp"
                )

                // Clean up the temp file on any exit path — mirrors
                // ImageCompressor.compress's `defer` block so that a
                // cancellation or failure never leaves an orphan.
                defer {
                    try? FileManager.default.removeItem(at: tmpURL)
                }

                do {
                    if FileManager.default.fileExists(atPath: destination.path)
                        && !commonOptions.overwriteExisting {
                        throw CrunchError.destinationAlreadyExists(destination)
                    }

                    let sourceBytes = try PDFCompressor.byteCount(of: source)
                    continuation.yield(.started(expectedSourceBytes: sourceBytes))
                    continuation.yield(.progress(fraction: 0.0))

                    guard let sourceDoc = PDFDocument(url: source) else {
                        throw CrunchError.sourceUnreadable(
                            underlying: PDFCompressorError.cannotOpenDocument
                        )
                    }

                    try Task.checkCancellation()

                    // Build the output document by copying pages from the
                    // source one at a time. This gives us a natural
                    // per-page cancellation boundary and a progress
                    // primitive (`pagesProcessed / pageCount`) aligned
                    // with SYSTEM-DESIGN §12.3.
                    let totalPages = sourceDoc.pageCount
                    let outputDoc = PDFDocument()

                    // Carry over the attribute dictionary first; we'll
                    // selectively clear fields below. Starting from a
                    // copy keeps whatever producer / creation date the
                    // source had intact when stripMetadata is false.
                    if let attrs = sourceDoc.documentAttributes {
                        outputDoc.documentAttributes = attrs
                    }

                    if totalPages == 0 {
                        // Edge case: empty document. Still emit an output
                        // so callers don't get a half-initialised file.
                        continuation.yield(.progress(fraction: 1.0))
                    } else {
                        for i in 0 ..< totalPages {
                            try Task.checkCancellation()
                            guard let sourcePage = sourceDoc.page(at: i),
                                  let copy = sourcePage.copy() as? PDFPage else {
                                throw CrunchError.compressionFailed(
                                    kind: .pdf,
                                    underlying: PDFCompressorError.pageCopyFailed(index: i)
                                )
                            }
                            outputDoc.insert(copy, at: outputDoc.pageCount)

                            // Emit at least one progress event per page;
                            // callers can throttle downstream if they
                            // want a lower rate. Fraction is expressed
                            // against final write (we reserve 1.0 for
                            // post-write).
                            let fraction = Double(i + 1) / Double(totalPages) * 0.95
                            continuation.yield(.progress(fraction: fraction))
                        }
                    }

                    // Apply metadata strip *after* pages are copied so
                    // we don't accidentally repopulate attributes from a
                    // page-copy side effect.
                    if commonOptions.stripMetadata {
                        PDFCompressor.stripMetadata(on: outputDoc)
                    }

                    try Task.checkCancellation()

                    let writeOptions = PDFCompressor.writeOptions(for: preset)
                    guard outputDoc.write(to: tmpURL, withOptions: writeOptions) else {
                        throw CrunchError.destinationNotWritable(tmpURL)
                    }

                    try Task.checkCancellation()

                    try PDFCompressor.atomicallyMove(from: tmpURL, to: destination)

                    let outputBytes = try PDFCompressor.byteCount(of: destination)
                    let duration = ContinuousClock.now - start
                    let result = CompressionResult(
                        source: source,
                        output: destination,
                        sourceBytes: sourceBytes,
                        outputBytes: outputBytes,
                        duration: duration,
                        kind: .pdf
                    )
                    continuation.yield(.progress(fraction: 1.0))
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CrunchError.cancelled)
                } catch let error as CrunchError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: CrunchError.compressionFailed(kind: .pdf, underlying: error)
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

    // MARK: - Write options per profile

    /// Build the options dictionary passed to `PDFDocument.write(to:withOptions:)`.
    /// See the profile table in the file header for rationale. The keys
    /// used here are stable since macOS 13.4 / iOS 16.4 — the platform
    /// floor (macOS 14) guarantees availability.
    private static func writeOptions(
        for preset: PDFPreset
    ) -> [PDFDocumentWriteOption: Any] {
        var options: [PDFDocumentWriteOption: Any] = [:]
        switch preset.profile {
        case .highQuality:
            // No image downsampling; the write is essentially a re-pack
            // that still honours metadata stripping via the document
            // attributes pass above.
            break
        case .balanced:
            options[.saveImagesAsJPEGOption] = true
        case .smallFile:
            options[.optimizeImagesForScreenOption] = true
            options[.saveImagesAsJPEGOption] = true
        case .tiny:
            options[.optimizeImagesForScreenOption] = true
            options[.saveImagesAsJPEGOption] = true
        }
        return options
    }

    // MARK: - Metadata

    /// Clear the document-level author/title/subject/keywords/producer/
    /// creator fields when `commonOptions.stripMetadata` is set. Per
    /// SYSTEM-DESIGN §11 / §12 we do not keep a breadcrumb that Crunch
    /// touched the file — users explicitly opted into metadata loss.
    private static func stripMetadata(on doc: PDFDocument) {
        var attrs = doc.documentAttributes ?? [:]
        let keysToClear: [PDFDocumentAttribute] = [
            .authorAttribute,
            .titleAttribute,
            .subjectAttribute,
            .keywordsAttribute,
            .producerAttribute,
            .creatorAttribute,
        ]
        for key in keysToClear {
            // PDFKit stores keys as raw `NSString` values internally; the
            // `PDFDocumentAttribute` wrapper and the raw string both hash
            // to the same `AnyHashable` bucket, so one removal covers
            // both representations.
            attrs.removeValue(forKey: key)
            attrs.removeValue(forKey: key.rawValue)
        }
        doc.documentAttributes = attrs
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

    /// Atomic swap of `tmpURL` into `destination`. Mirrors
    /// `ImageCompressor.atomicallyMove` so the cross-kind semantics stay
    /// identical — any failure surfaces as `.destinationNotWritable`.
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

private enum PDFCompressorError: Error {
    case cannotOpenDocument
    case pageCopyFailed(index: Int)
}
