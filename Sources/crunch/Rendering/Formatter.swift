import Foundation

/// Display-formatting helpers used by the CLI.
enum CLIFormatter {
    /// Format a byte count using `ByteCountFormatter` (`"12.3 MB"`).
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: value)
    }

    /// Format a `Duration` as a short human-readable string (`"2.3s"`).
    static func duration(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let totalSeconds = Double(seconds) + Double(attoseconds) / 1e18
        if totalSeconds < 1.0 {
            return String(format: "%.0fms", totalSeconds * 1000)
        }
        if totalSeconds < 60 {
            return String(format: "%.1fs", totalSeconds)
        }
        let fmt = DateComponentsFormatter()
        fmt.unitsStyle = .abbreviated
        fmt.allowedUnits = [.minute, .second]
        return fmt.string(from: totalSeconds) ?? "\(Int(totalSeconds))s"
    }

    /// Format a savings ratio as a percentage with a leading minus sign
    /// (`"−82%"`). Handles zero and negative ratios (passthrough, grew).
    static func savings(_ ratio: Double) -> String {
        let pct = Int((ratio * 100).rounded())
        if pct <= 0 {
            return "\(pct)%"
        }
        return "\u{2212}\(pct)%"
    }
}
