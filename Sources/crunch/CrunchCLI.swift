import ArgumentParser
import Foundation

/// Top-level `crunch` CLI. `CompressCommand` is the default subcommand,
/// so `crunch video.mp4` works without typing `compress`.
@main
struct CrunchCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crunch",
        abstract: "Compress video, image, PDF and audio files locally on your Mac.",
        version: "0.1.0-dev",
        subcommands: [CompressCommand.self, ListPresetsCommand.self],
        defaultSubcommand: CompressCommand.self
    )
}
