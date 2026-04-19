import Foundation

/// The public entry point for CrunchCore. Every compression job flows
/// through `Crunch.compress(_:)` — concrete compressor implementations
/// are internal and not addressable by callers.
public enum Crunch {
    /// Detect the file kind at `url` using the same rules `Crunch.compress`
    /// applies internally. Use this to resolve a kind-agnostic
    /// `ProfileName` to a concrete `Preset` before building a
    /// `CompressionRequest` — the CLI and scripting callers rely on this
    /// to avoid duplicating detection logic.
    ///
    /// Throws `CrunchError.sourceUnreadable` if the file can't be opened,
    /// or `CrunchError.unsupportedFormat` if its kind can't be determined.
    public static func detectKind(at url: URL) throws -> FileKind {
        try FileKindDetector.detect(at: url)
    }

    /// Compress a file according to `request`. Returns an
    /// `AsyncThrowingStream` that yields `.started`, zero or more
    /// `.progress` values, and exactly one `.finished` — or throws a
    /// `CrunchError` (including `.cancelled` when `Task.cancel()` is
    /// called on the consuming task).
    public static func compress(
        _ request: CompressionRequest
    ) -> AsyncThrowingStream<CompressionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. Detect the source's real kind.
                    let detectedKind = try FileKindDetector.detect(at: request.source)

                    // 2. Reject kind/preset mismatches before any I/O.
                    guard detectedKind == request.preset.kind else {
                        throw CrunchError.presetKindMismatch(
                            expected: detectedKind,
                            got: request.preset.kind
                        )
                    }

                    // 3. Resolve destination URL. OutputNaming rejects paths
                    //    that resolve to the source file itself.
                    let resolvedDestination = try OutputNaming.resolve(
                        request.destination,
                        source: request.source
                    )
                    let destination = OutputNaming.normalizedAlongsideExtension(
                        for: resolvedDestination,
                        destination: request.destination,
                        preset: request.preset
                    )

                    // 4. Dispatch on the preset sum. Each case carries the
                    //    concrete kind-scoped preset, preserving full type
                    //    information without existential erasure.
                    let stream: AsyncThrowingStream<CompressionEvent, Error>
                    switch request.preset {
                    case .video(let preset):
                        stream = VideoCompressor().compress(
                            source: request.source,
                            destination: destination,
                            preset: preset,
                            commonOptions: request.commonOptions
                        )
                    case .image(let preset):
                        stream = ImageCompressor().compress(
                            source: request.source,
                            destination: destination,
                            preset: preset,
                            commonOptions: request.commonOptions
                        )
                    case .pdf(let preset):
                        stream = PDFCompressor().compress(
                            source: request.source,
                            destination: destination,
                            preset: preset,
                            commonOptions: request.commonOptions
                        )
                    case .audio(let preset):
                        stream = AudioCompressor().compress(
                            source: request.source,
                            destination: destination,
                            preset: preset,
                            commonOptions: request.commonOptions
                        )
                    }

                    // 5. Forward events until the inner stream terminates.
                    for try await event in stream {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CrunchError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }
}
