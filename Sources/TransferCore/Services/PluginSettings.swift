import Foundation

public struct PluginSettings: Equatable, Sendable {
    public var finderAccessibilityFallback: Bool
    public var showDriveConnected: Bool

    public init(finderAccessibilityFallback: Bool = false, showDriveConnected: Bool = true) {
        self.finderAccessibilityFallback = finderAccessibilityFallback
        self.showDriveConnected = showDriveConnected
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> PluginSettings {
        var values: [String: Any] = [:]
        if let path = environment["DYNAMICLAKE_PLUGIN_SETTINGS_PATH"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values = object["values"] as? [String: Any] ?? object
        }
        return PluginSettings(
            finderAccessibilityFallback: bool(values["finderAccessibilityFallback"] ?? environment["DYNAMICLAKE_SETTING_FINDER_ACCESSIBILITY_FALLBACK"], default: false),
            showDriveConnected: bool(values["showDriveConnected"] ?? environment["DYNAMICLAKE_SETTING_SHOW_DRIVE_CONNECTED"], default: true)
        )
    }

    private static func bool(_ value: Any?, default defaultValue: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return !["0", "false", "no", "off"].contains(value.lowercased()) }
        return defaultValue
    }
}
