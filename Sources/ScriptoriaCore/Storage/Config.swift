import Foundation

/// App configuration
///
/// Everything (config.json, scripts.json, schedules.json, history/) lives in ONE directory.
/// Default: ~/.scriptoria/
/// Can be changed to iCloud or any custom path.
public struct Config: Codable, Sendable {
    /// The single directory where ALL Scriptoria data lives
    /// (config.json, scripts.json, schedules.json, history/)
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

    /// iCloud Drive .scriptoria path
    public static var iCloudDataDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Mobile Documents/com~apple~CloudDocs/.scriptoria"
    }

    /// Config file path (inside the data directory)
    public var configFilePath: String {
        "\(dataDirectory)/config.json"
    }

    /// Pointer file: a tiny file at the default location that tells us where the real data directory is.
    /// This lets CLI and App find data even when it's been moved to iCloud/custom path.
    private static var pointerFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.scriptoria/pointer.json"
    }

    // MARK: - Pointer (tells us where data lives)

    private struct Pointer: Codable {
        var dataDirectory: String
    }

    /// Resolve the actual data directory by reading the pointer file
    public static func resolveDataDirectory() -> String {
        let pointerPath = pointerFilePath
        if FileManager.default.fileExists(atPath: pointerPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: pointerPath)),
           let pointer = try? JSONDecoder().decode(Pointer.self, from: data) {
            return pointer.dataDirectory
        }
        return defaultDataDirectory
    }

    /// Save the pointer file so CLI/App can find the data directory
    private static func savePointer(dataDirectory: String) throws {
        let pointerPath = pointerFilePath
        let dir = URL(fileURLWithPath: pointerPath).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let pointer = Pointer(dataDirectory: dataDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(pointer)
        try data.write(to: URL(fileURLWithPath: pointerPath), options: .atomic)
    }

    // MARK: - Load / Save

    /// Load config: resolve data directory from pointer, then read config.json from there
    public static func load() -> Config {
        let dataDir = resolveDataDirectory()
        let configPath = "\(dataDir)/config.json"

        if FileManager.default.fileExists(atPath: configPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        return Config(dataDirectory: dataDir)
    }

    /// Save config.json into the data directory, and update the pointer
    public func save() throws {
        // Ensure data directory exists
        if !FileManager.default.fileExists(atPath: dataDirectory) {
            try FileManager.default.createDirectory(
                atPath: dataDirectory, withIntermediateDirectories: true
            )
        }

        // Write config.json into data directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: configFilePath), options: .atomic)

        // Update pointer so CLI/App can find us
        try Config.savePointer(dataDirectory: dataDirectory)
    }
}
