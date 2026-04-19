import ArgumentParser
import CrunchCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Default subcommand — compresses one or more files.
struct CompressCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compress",
        abstract: "Compress one or more files.",
        shouldDisplay: true
    )

    @Argument(help: "Source files. Accepts one or more paths.")
    var sources: [String] = []

    @Option(name: [.customShort("o"), .long], help: "Output path (single-source only).")
    var output: String?

    @Option(name: .long, help: "Preset name. See `crunch list-presets` for the matrix.")
    var preset: String = "balanced"

    @Flag(name: .long, help: "Overwrite existing output files.")
    var overwrite: Bool = false

    @Flag(name: .customLong("strip-metadata"), help: "Strip EXIF / GPS / IPTC / ID3 metadata.")
    var stripMetadata: Bool = false

    @Flag(name: .long, help: "Suppress progress output.")
    var quiet: Bool = false

    @Flag(name: .long, help: "Emit line-delimited JSON events to stdout.")
    var json: Bool = false

    func run() async throws {
        if sources.isEmpty {
            throw ValidationError("at least one source file is required.")
        }
        if output != nil && sources.count > 1 {
            throw ValidationError("--output / -o only works with a single source file.")
        }

        let profile = try parsePreset(preset)
        let snapshot = self

        // SIGINT → cancel the top-level Task so Crunch.compress stops and
        // cleans up via its `defer` blocks. Exit code 130 per §10.3.
        let topTask = Task<Int32, Never> {
            await snapshot.runAll(profileName: profile)
        }
        CompressCommand.installSIGINTHandler(cancelling: topTask)

        let exitCode = await topTask.value
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    private func parsePreset(_ raw: String) throws -> ProfileName {
        // Accept kebab-case (canonical), camelCase, and lowercased variants.
        let normalized = raw.lowercased()
        if let p = ProfileName(rawValue: normalized) {
            return p
        }
        let kebab = CompressCommand.camelToKebab(raw)
        if let p = ProfileName(rawValue: kebab) {
            return p
        }
        let valid = ProfileName.allCases.map(\.rawValue).joined(separator: ", ")
        throw ValidationError("unknown preset '\(raw)'. Valid: \(valid).")
    }

    private static func camelToKebab(_ input: String) -> String {
        var output = ""
        for char in input {
            if char.isUppercase {
                if !output.isEmpty { output.append("-") }
                output.append(Character(char.lowercased()))
            } else {
                output.append(char)
            }
        }
        return output
    }

    // MARK: - Drive the queue

    private func runAll(profileName: ProfileName) async -> Int32 {
        var firstNonZero: Int32 = 0
        var anySucceeded = false

        for (index, sourcePath) in sources.enumerated() {
            if Task.isCancelled {
                if firstNonZero == 0 { firstNonZero = 130 }
                break
            }
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let outcome = await runOne(
                sourceURL: sourceURL,
                profileName: profileName,
                isSingleFile: sources.count == 1,
                index: index
            )
            if outcome.succeeded {
                anySucceeded = true
            }
            if outcome.exitCode != 0 && firstNonZero == 0 {
                firstNonZero = outcome.exitCode
            }
        }
        _ = anySucceeded
        return firstNonZero
    }

    private struct FileOutcome { let succeeded: Bool; let exitCode: Int32 }

    private func runOne(
        sourceURL: URL,
        profileName: ProfileName,
        isSingleFile: Bool,
        index: Int
    ) async -> FileOutcome {
        // Detection happens inside Core too, but we need the kind up front
        // to resolve the profile → preset. A failure here is a core error.
        let detectedKind: FileKind
        do {
            detectedKind = try publicDetect(at: sourceURL)
        } catch let error as CrunchError {
            reportError(error, sourceURL: sourceURL)
            return FileOutcome(succeeded: false, exitCode: exitCode(for: error))
        } catch {
            emitError("error: \(error.localizedDescription)")
            return FileOutcome(succeeded: false, exitCode: 1)
        }

        let presetValue: Preset
        do {
            presetValue = try profileName.resolve(for: detectedKind)
        } catch let error as CrunchError {
            reportError(error, sourceURL: sourceURL)
            return FileOutcome(succeeded: false, exitCode: exitCode(for: error))
        } catch {
            emitError("error: \(error.localizedDescription)")
            return FileOutcome(succeeded: false, exitCode: 1)
        }

        let destination: CompressionRequest.Destination
        if let output, isSingleFile {
            destination = .explicit(URL(fileURLWithPath: output))
        } else {
            destination = .alongsideSource(suffix: "_crunched")
        }

        let request = CompressionRequest(
            source: sourceURL,
            destination: destination,
            preset: presetValue,
            commonOptions: .init(
                overwriteExisting: overwrite,
                stripMetadata: stripMetadata
            )
        )

        let bar = ProgressBar(fileName: sourceURL.lastPathComponent, quiet: quiet || json)

        do {
            for try await event in Crunch.compress(request) {
                try Task.checkCancellation()
                switch event {
                case .started(let sourceBytes):
                    if json {
                        emitJSON([
                            "event": "started",
                            "source": sourceURL.path,
                            "sourceBytes": sourceBytes,
                            "kind": detectedKind.rawValue,
                        ])
                    } else {
                        bar.start(expectedSourceBytes: sourceBytes)
                    }
                case .progress(let fraction):
                    if json {
                        emitJSON([
                            "event": "progress",
                            "source": sourceURL.path,
                            "fraction": fraction,
                        ])
                    } else {
                        bar.update(fraction: fraction)
                    }
                case .finished(let result):
                    if json {
                        emitJSON([
                            "event": "finished",
                            "source": result.source.path,
                            "output": result.output.path,
                            "sourceBytes": result.sourceBytes,
                            "outputBytes": result.outputBytes,
                            "savingsRatio": result.savingsRatio,
                            "kind": result.kind.rawValue,
                        ])
                    } else {
                        bar.finish(result: CompressionResultDisplay(
                            outputName: result.output.lastPathComponent,
                            outputBytes: result.outputBytes,
                            savingsRatio: result.savingsRatio,
                            duration: result.duration
                        ))
                    }
                }
            }
            return FileOutcome(succeeded: true, exitCode: 0)
        } catch is CancellationError {
            return FileOutcome(succeeded: false, exitCode: 130)
        } catch let error as CrunchError {
            reportError(error, sourceURL: sourceURL)
            return FileOutcome(succeeded: false, exitCode: exitCode(for: error))
        } catch {
            emitError("error: \(error.localizedDescription)")
            return FileOutcome(succeeded: false, exitCode: 1)
        }
    }

    /// `FileKindDetector` is `internal`; we expose detection through a
    /// tiny throwing call that mirrors the library's behaviour by running
    /// a detect-only preflight via `Crunch.compress` is too heavy — instead
    /// we rely on the same detection rules using public API here. Keep the
    /// CLI-side detector to just parsing UTType + trivial extension sniff.
    private func publicDetect(at url: URL) throws -> FileKind {
        // We can't call the internal detector, so mimic its logic with the
        // subset the CLI needs: extension + header sniff of the first bytes.
        // Full detection happens inside `Crunch.compress` — this is only
        // used to map ProfileName → Preset.kind ahead of time.
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "m4v", "mkv", "webm", "avi":
            return .video
        case "jpg", "jpeg", "png", "heic", "tiff", "tif", "webp", "bmp", "gif":
            return .image
        case "pdf":
            return .pdf
        case "mp3", "wav", "aac", "m4a", "flac", "aiff", "aif", "ogg":
            return .audio
        default:
            break
        }
        // Fallback: open & sniff the first 16 bytes.
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 16) else {
            throw CrunchError.unsupportedFormat(detected: ext.isEmpty ? "<no extension>" : ext)
        }
        defer { try? handle.close() }
        let bytes = [UInt8](data)
        if bytes.count >= 4 {
            if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image }
            if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .image }
            if bytes.starts(with: [0x49, 0x44, 0x33]) { return .audio }
            if bytes.count >= 12 && Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
                return .video
            }
        }
        throw CrunchError.unsupportedFormat(detected: ext.isEmpty ? "<no extension>" : ext)
    }

    // MARK: - Error reporting + exit code mapping

    private func reportError(_ error: CrunchError, sourceURL: URL) {
        emitError("error: \(sourceURL.lastPathComponent): \(error)")
        if case .presetNotApplicable(_, let kind) = error {
            let allowed = ProfileName.allowedForKind[kind, default: []]
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")
            emitError("hint:  presets valid for \(kind.rawValue): \(allowed)")
        }
    }

    private func exitCode(for error: CrunchError) -> Int32 {
        switch error {
        case .unsupportedFormat:
            return 2
        case .sourceUnreadable, .destinationNotWritable,
             .destinationAlreadyExists, .insufficientDiskSpace:
            return 3
        case .compressionFailed:
            return 4
        case .presetKindMismatch, .presetNotApplicable:
            return 5
        case .cannotMeetSizeTarget:
            return 6
        case .cancelled:
            return 130
        }
    }

    private func emitError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func emitJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        print(line)
    }

    private static func installSIGINTHandler(cancelling task: Task<Int32, Never>) {
        #if canImport(Darwin)
        let nonisolatedTask = task
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            nonisolatedTask.cancel()
        }
        source.resume()
        signal(SIGINT, SIG_IGN)
        // Leak the source intentionally — it lives for the lifetime of the CLI.
        _ = Unmanaged.passRetained(source as AnyObject)
        #endif
    }
}
