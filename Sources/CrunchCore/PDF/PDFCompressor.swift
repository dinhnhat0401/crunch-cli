import Foundation

/// v0.1 stub — real PDFKit-backed compression lands in v0.1 final (post-scaffold).
struct PDFCompressor: Compressor {
    typealias KindPreset = PDFPreset

    func compress(
        source: URL,
        destination: URL,
        preset: PDFPreset,
        commonOptions: CompressionRequest.CommonOptions
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: CrunchError.compressionFailed(
                    kind: .pdf,
                    underlying: NSError(
                        domain: "CrunchCore",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "pdf compression not yet implemented in v0.1"]
                    )
                )
            )
        }
    }
}
