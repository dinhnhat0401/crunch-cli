import Foundation

/// v0.1 stub — real AVAudioConverter-backed compression lands in v0.2.
struct AudioCompressor: Compressor {
    typealias KindPreset = AudioPreset

    func compress(
        source: URL,
        destination: URL,
        preset: AudioPreset,
        commonOptions: CompressionRequest.CommonOptions
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: CrunchError.compressionFailed(
                    kind: .audio,
                    underlying: NSError(
                        domain: "CrunchCore",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "audio compression not yet implemented in v0.1"]
                    )
                )
            )
        }
    }
}
