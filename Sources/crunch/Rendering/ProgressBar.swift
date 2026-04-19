import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// TTY-aware progress renderer. When stdout is a terminal, draws an ANSI
/// progress bar in place; otherwise emits one line per lifecycle event so
/// logs and CI output stay readable.
final class ProgressBar {
    private let fileName: String
    private let isTTY: Bool
    private let quiet: Bool
    private var lastRenderedFraction: Double = -1
    private var hasDrawn = false

    init(fileName: String, quiet: Bool) {
        self.fileName = fileName
        self.quiet = quiet
        #if canImport(Darwin)
        self.isTTY = isatty(fileno(stdout)) != 0
        #else
        self.isTTY = false
        #endif
    }

    /// Called on `.started` — prints a header.
    func start(expectedSourceBytes: Int64) {
        guard !quiet else { return }
        if isTTY {
            print("▸ \(fileName)  \(CLIFormatter.bytes(expectedSourceBytes))")
        } else {
            print("\(fileName): started (\(CLIFormatter.bytes(expectedSourceBytes)))")
        }
    }

    /// Called on `.progress(fraction:)`.
    func update(fraction: Double) {
        guard !quiet else { return }
        let clamped = max(0.0, min(1.0, fraction))
        if isTTY {
            // Throttle redraws to whole-percent changes.
            guard Int(clamped * 100) != Int(lastRenderedFraction * 100) else { return }
            lastRenderedFraction = clamped
            let width = 20
            let filled = Int(clamped * Double(width))
            let bar = String(repeating: "\u{2588}", count: filled)
                + String(repeating: "\u{2591}", count: width - filled)
            let pct = Int(clamped * 100)
            if hasDrawn {
                print("\u{001B}[1A\u{001B}[2K", terminator: "")
            }
            print("  [\(bar)]  \(pct)%")
            hasDrawn = true
        } else {
            let pct = Int(clamped * 100)
            print("\(fileName): \(pct)%")
        }
    }

    /// Called on `.finished(result)`.
    func finish(result: CompressionResultDisplay) {
        guard !quiet else { return }
        let sizeOut = CLIFormatter.bytes(result.outputBytes)
        let savings = CLIFormatter.savings(result.savingsRatio)
        let dur = CLIFormatter.duration(result.duration)
        if isTTY {
            if hasDrawn {
                print("\u{001B}[1A\u{001B}[2K", terminator: "")
            }
            print("  \u{2713} \(result.outputName)  \(sizeOut)  (\(savings))  in \(dur)")
        } else {
            print("\(fileName): done → \(result.outputName) \(sizeOut) (\(savings)) in \(dur)")
        }
    }
}

/// Value type snapshot of the parts of `CompressionResult` the CLI prints,
/// kept in the CLI target so the renderer doesn't leak into `CrunchCore`.
struct CompressionResultDisplay {
    let outputName: String
    let outputBytes: Int64
    let savingsRatio: Double
    let duration: Duration
}
