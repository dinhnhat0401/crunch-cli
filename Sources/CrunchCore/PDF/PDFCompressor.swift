import Foundation
import PDFKit
import ImageIO
import CoreGraphics
import Quartz
import UniformTypeIdentifiers

/// PDF compressor using PDFKit's `writeToURL(withOptions:)` pipeline with
/// Quartz image filters. This keeps PDF text/vector structure intact while
/// letting us tune embedded raster image resampling and JPEG quality per
/// preset. The writer also enables `saveTextFromOCROption` so OCR text stays
/// in the output when the source carries it.
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
/// The per-profile DPI ladder is implemented with Quartz filter image
/// settings rather than PDFKit's blunt "optimize for screen" toggle:
///
/// | Profile     | optimize | jpeg | Intent                              |
/// |-------------|----------|------|-------------------------------------|
/// | highQuality | 150 DPI / q0.85 | archive / print-safe |
/// | balanced    | 120 DPI / q0.70 | default sharing      |
/// | smallFile   | 96 DPI / q0.55  | email / web          |
/// | tiny        | 72 DPI / q0.40  | aggressive sharing   |
///
/// This gives the profiles real separation without rasterizing whole pages,
/// which would violate the SYSTEM-DESIGN §9.3 invariant that searchable text
/// and document structure survive compression.
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
                    try DiskSpaceGuard.assertSufficientSpace(
                        at: destination,
                        requiredBytes: max(sourceBytes, 16 * 1024 * 1024)
                    )

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

                    let finalOutputBytes = try OutputPreserver.replaceWithSourceIfLarger(
                        source: source,
                        candidate: tmpURL,
                        sourceBytes: sourceBytes,
                        sourceExtension: source.pathExtension,
                        candidateExtension: "pdf",
                        stripMetadata: commonOptions.stripMetadata,
                        allowsPassthrough: true
                    )

                    try Task.checkCancellation()

                    try PDFCompressor.atomicallyMove(from: tmpURL, to: destination)

                    let duration = ContinuousClock.now - start
                    let result = CompressionResult(
                        source: source,
                        output: destination,
                        sourceBytes: sourceBytes,
                        outputBytes: finalOutputBytes,
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
        var options: [PDFDocumentWriteOption: Any] = [
            PDFDocumentWriteOption.saveTextFromOCROption: true,
        ]
        if let filter = quartzFilter(for: preset.profile) {
            options[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = filter
        }
        return options
    }

    private static func quartzFilter(
        for profile: PDFPreset.Profile
    ) -> QuartzFilter? {
        let settings = quartzImageSettings(for: profile)
        let properties: [String: Any] = [
            "Name": "Crunch \(profile.filterNameSuffix)",
            "FilterType": NSNumber(value: 1),
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": NSNumber(value: settings.compressionQuality),
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": NSNumber(value: settings.resolution),
                            "ImageScaleInterpolate": NSNumber(value: 1),
                            "ImageSizeMax": NSNumber(value: settings.maxDimension),
                            "ImageSizeMin": NSNumber(value: 0),
                        ],
                    ],
                ],
            ],
        ]
        return QuartzFilter(properties: properties)
    }

    private static func quartzImageSettings(
        for profile: PDFPreset.Profile
    ) -> QuartzImageSettings {
        switch profile {
        case .highQuality:
            return .init(resolution: 150, maxDimension: 3000, compressionQuality: 0.85)
        case .balanced:
            return .init(resolution: 120, maxDimension: 2200, compressionQuality: 0.70)
        case .smallFile:
            return .init(resolution: 96, maxDimension: 1600, compressionQuality: 0.55)
        case .tiny:
            return .init(resolution: 72, maxDimension: 1200, compressionQuality: 0.40)
        }
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

private struct QuartzImageSettings {
    let resolution: Int
    let maxDimension: Int
    let compressionQuality: Double
}

private extension PDFPreset.Profile {
    var filterNameSuffix: String {
        switch self {
        case .highQuality: return "High Quality"
        case .balanced: return "Balanced"
        case .smallFile: return "Small File"
        case .tiny: return "Tiny"
        }
    }
}

private enum PDFCompressorError: Error {
    case cannotOpenDocument
    case pageCopyFailed(index: Int)
}
