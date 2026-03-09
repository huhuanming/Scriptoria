import Foundation

/// App configuration, stored at a fixed location ~/.scriptoria/config.json
public struct Config: Codable, Sendable {
    /// Where script data is stored (scripts.json, schedules.json, history/)
    /// Examples:
    ///   - ~/.scriptoria  (default, local)
    ///   - ~/Library/Mobile Documents/com~apple~CloudDocs/.scriptoria  (iCloud)
    public var dataDirectory: String

    /// Whether to send notifications on script completion
    public var notifyOnCompletion: Bool

    /// Whether to show running indicator in menu bar icon
    public var showRunningIndicator: Bool

    public init(
        dataDirectory: String? = nil,
        notifyOnCompletion: Bool = true,
        showRunningIndicator: Bool = true
    ) {
        self.dataDirectory = dataDirectory ?? Config.defaultDataDirectory
        self.notifyOnCompletion = notifyOnCompletion
        self.showRunningIndicator = showRunningIndicator
    }

    // MARK: - Paths

    /// Default data directory
    public static var defaultDataDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.scriptoria"
    }

    /// Fixed config file location (always local, never in iCloud)
    public static var configFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.scriptoria/config.json"
    }

    /// iCloud Drive .scriptoria path
    public static var iCloudDataDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Mobile Documents/com~apple~CloudDocs/.scriptoria"
    }

    // MARK: - Load / Save

    /// Load config from disk, or return default
    public static func load() -> Config {
        let path = configFilePath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return Config()
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(Config.self, from: data)) ?? Config()
    }

    /// Save config to disk
    public func save() throws {
        let path = Config.configFilePath
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
