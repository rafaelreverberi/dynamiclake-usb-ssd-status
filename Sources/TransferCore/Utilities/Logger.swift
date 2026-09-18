import Foundation

public final class Logger {
    public static let shared = Logger()
    public var isDebugEnabled = false
    private let queue = DispatchQueue(label: "com.rafaelreverberi.usb-ssd-status.logger")
    private let formatter = ISO8601DateFormatter()

    private init() {}

    public func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    public func warning(_ message: @autoclosure () -> String) { write("WARN", message()) }
    public func debug(_ message: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        write("DEBUG", message())
    }

    public var logURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("DynamicLake/PluginLogs/usb-ssd-status-debug.log")
    }

    private func write(_ level: String, _ message: String) {
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(formatter.string(from: Date())) [\(level)] \(sanitized)\n"
        if isDebugEnabled { fputs(line, stderr) }
        queue.async { [logURL] in
            let directory = logURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let size = attributes[.size] as? NSNumber, size.intValue > 512 * 1024 {
                try? Data().write(to: logURL, options: .atomic)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }
}
