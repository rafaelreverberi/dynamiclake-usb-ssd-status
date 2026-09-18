import Foundation

public enum TransferFormatters {
    public static func bytes(_ value: Int64?) -> String? {
        guard let value, value >= 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }

    public static func percentage(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite else { return nil }
        return "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    public static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \((total % 3_600) / 60)m"
    }

    public static func throughput(_ bytesPerSecond: Int64?) -> String? {
        guard let bytesPerSecond, bytesPerSecond >= 0, let value = bytes(bytesPerSecond) else { return nil }
        return "\(value)/s"
    }
}
