import Foundation

/// v0.1 stub — real AVFoundation-backed video compression lands in v0.2.
struct VideoCompressor: Compressor {
    typealias KindPreset = VideoPreset

    func compress(
        source: URL,
        destination: URL,
        preset: VideoPreset,
        commonOptions: CompressionRequest.CommonOptions
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: CrunchError.compressionFailed(
                    kind: .video,
                    underlying: NSError(
                        domain: "CrunchCore",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "video compression not yet implemented in v0.1"]
                    )
                )
            )
        }
    }
}
