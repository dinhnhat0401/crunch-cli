import Foundation

/// Internal protocol implemented by each per-kind compressor
/// (`ImageCompressor`, `VideoCompressor`, ...). The kind-scoped preset is
/// bound through the `KindPreset` associated type, which is why dispatch
/// in `Crunch.compress` switches on the `Preset` sum directly rather than
/// through an existential — see ARCHITECTURE-ENGINE.md §3.
protocol Compressor: Sendable {
    associatedtype KindPreset: Sendable

    func compress(
        source: URL,
        destination: URL,
        preset: KindPreset,
        commonOptions: CompressionRequest.CommonOptions
    ) -> AsyncThrowingStream<CompressionEvent, Error>
}
