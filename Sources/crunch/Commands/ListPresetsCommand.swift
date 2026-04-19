import ArgumentParser
import CrunchCore
import Foundation

/// `crunch list-presets` — prints the preset/kind compatibility matrix.
struct ListPresetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-presets",
        abstract: "Show which presets apply to which file kinds.",
        shouldDisplay: true
    )

    func run() async throws {
        let kindOrder: [FileKind] = [.video, .image, .pdf, .audio]
        let allProfiles = ProfileName.allCases.sorted { $0.rawValue < $1.rawValue }

        let leftWidth = max(
            "preset".count,
            allProfiles.map { $0.rawValue.count }.max() ?? 0
        )

        // Header row.
        var header = "preset".padding(toLength: leftWidth, withPad: " ", startingAt: 0)
        for kind in kindOrder {
            header += "  "
            header += kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
        }
        print(header)

        let divider = String(repeating: "-", count: leftWidth)
            + "  " + kindOrder.map { _ in "-----" }.joined(separator: "  ")
        print(divider)

        for profile in allProfiles {
            var row = profile.rawValue.padding(toLength: leftWidth, withPad: " ", startingAt: 0)
            for kind in kindOrder {
                let ok = ProfileName.allowedForKind[kind, default: []].contains(profile)
                let cell = ok ? "  yes" : "   - "
                row += "  " + cell.padding(toLength: 5, withPad: " ", startingAt: 0)
            }
            print(row)
        }
    }
}
