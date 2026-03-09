import Foundation

/// App configuration
///
/// Data directory layout:
///   {dataDirectory}/db/scriptoria.db   — SQLite database with all data
///   {dataDirectory}/scripts/           — Script files (e.g. hello-world.sh)
/// Pointer file at ~/.scriptoria/pointer.json tells CLI/App where the data directory is.
public struct Config: Codable, Sendable {
    /// The single directory where ALL Scriptoria data lives
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

    /// Scripts subdirectory within the data directory
    public var scriptsDirectory: String {
        "\(dataDirectory)/scripts"
    }

    /// Database subdirectory within the data directory
    public var dbDirectory: String {
        "\(dataDirectory)/db"
    }

    /// Logs subdirectory within the data directory
    public var logsDirectory: String {
        "\(dataDirectory)/logs"
    }

    /// Pointer file: a tiny file at the default location that tells us where the real data directory is.
    private static var pointerFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.scriptoria/pointer.json"
    }

    // MARK: - Pointer (tells us where data lives)

    private struct Pointer: Codable {
        var dataDirectory: String
    }

    /// Resolve the actual data directory by reading the pointer file.
    /// Falls back to the default directory if the pointer target is inaccessible.
    public static func resolveDataDirectory() -> String {
        let pointerPath = pointerFilePath
        if FileManager.default.fileExists(atPath: pointerPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: pointerPath)),
           let pointer = try? JSONDecoder().decode(Pointer.self, from: data) {
            // Verify the directory is accessible
            if FileManager.default.isWritableFile(atPath: pointer.dataDirectory) {
                return pointer.dataDirectory
            }
            // Try to create it — if it fails, the directory is inaccessible
            if (try? FileManager.default.createDirectory(
                atPath: pointer.dataDirectory, withIntermediateDirectories: true)) != nil,
               FileManager.default.isWritableFile(atPath: pointer.dataDirectory) {
                return pointer.dataDirectory
            }
            // Fall back to default
            return defaultDataDirectory
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

    /// Load config: resolve data directory, then read settings from SQLite (falling back to JSON for migration)
    public static func load() -> Config {
        let dataDir = resolveDataDirectory()

        // Migrate legacy layout: db at root → db/ subdirectory
        let legacyDBPath = "\(dataDir)/scriptoria.db"
        let dbPath = "\(dataDir)/db/scriptoria.db"
        if FileManager.default.fileExists(atPath: legacyDBPath) && !FileManager.default.fileExists(atPath: dbPath) {
            migrateLegacyLayout(dataDir: dataDir)
        }

        // Try loading from SQLite first
        if FileManager.default.fileExists(atPath: dbPath) {
            if let db = try? DatabaseManager(directory: dataDir) {
                let notify = (try? db.getConfig(key: "notifyOnCompletion")) ?? "true"
                let showIndicator = (try? db.getConfig(key: "showRunningIndicator")) ?? "true"
                return Config(
                    dataDirectory: dataDir,
                    notifyOnCompletion: notify == "true",
                    showRunningIndicator: showIndicator == "true"
                )
            }
        }

        // Fallback: try legacy config.json
        let configPath = "\(dataDir)/config.json"
        if FileManager.default.fileExists(atPath: configPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }

        return Config(dataDirectory: dataDir)
    }

    /// Migrate legacy layout: move db and scripts from root into subdirectories
    private static func migrateLegacyLayout(dataDir: String) {
        let fm = FileManager.default

        // Move database files into db/
        let dbDir = "\(dataDir)/db"
        try? fm.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        for file in ["scriptoria.db", "scriptoria.db-wal", "scriptoria.db-shm"] {
            let src = "\(dataDir)/\(file)"
            let dst = "\(dbDir)/\(file)"
            if fm.fileExists(atPath: src) {
                try? fm.moveItem(atPath: src, toPath: dst)
            }
        }

        // Move script files into scripts/
        let scriptsDir = "\(dataDir)/scripts"
        try? fm.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)
        if let files = try? fm.contentsOfDirectory(atPath: dataDir) {
            let scriptExtensions = ["sh", "py", "rb", "js", "zsh", "pl", "swift"]
            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                if scriptExtensions.contains(ext) {
                    let src = "\(dataDir)/\(file)"
                    let dst = "\(scriptsDir)/\(file)"
                    if !fm.fileExists(atPath: dst) {
                        try? fm.moveItem(atPath: src, toPath: dst)
                    }
                }
            }
        }
    }

    // MARK: - Data Directory Migration

    /// Migrate database file from one data directory to another.
    /// Copies scriptoria.db to the new directory, then cleans up the old directory
    /// (removing everything except pointer.json if the old directory is ~/.scriptoria/).
    public static func migrateDataDirectory(from oldDir: String, to newDir: String) throws {
        let fm = FileManager.default

        // Ensure new directory exists
        if !fm.fileExists(atPath: newDir) {
            try fm.createDirectory(atPath: newDir, withIntermediateDirectories: true)
        }

        // Ensure new subdirectories exist
        let newDBDir = "\(newDir)/db"
        let newScriptsDir = "\(newDir)/scripts"
        for dir in [newDBDir, newScriptsDir] {
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }

        // Copy database files from old db/ subdirectory (or old root for legacy layout)
        let oldDBDir = "\(oldDir)/db"
        let oldDBLegacy = oldDir  // legacy: db was directly in dataDirectory
        let sourceDBDir = fm.fileExists(atPath: "\(oldDBDir)/scriptoria.db") ? oldDBDir : oldDBLegacy

        for file in ["scriptoria.db", "scriptoria.db-wal", "scriptoria.db-shm"] {
            let oldFile = "\(sourceDBDir)/\(file)"
            let newFile = "\(newDBDir)/\(file)"
            if fm.fileExists(atPath: oldFile) && !fm.fileExists(atPath: newFile) {
                try fm.copyItem(atPath: oldFile, toPath: newFile)
            }
        }

        // Copy script files from old scripts/ subdirectory (or old root for legacy layout)
        let oldScriptsDir = "\(oldDir)/scripts"
        let scriptsSource = fm.fileExists(atPath: oldScriptsDir) ? oldScriptsDir : oldDir
        if let files = try? fm.contentsOfDirectory(atPath: scriptsSource) {
            for file in files where file.hasSuffix(".sh") || file.hasSuffix(".py") || file.hasSuffix(".rb") || file.hasSuffix(".js") || file.hasSuffix(".zsh") {
                let oldFile = "\(scriptsSource)/\(file)"
                let newFile = "\(newScriptsDir)/\(file)"
                if !fm.fileExists(atPath: newFile) {
                    try? fm.copyItem(atPath: oldFile, toPath: newFile)
                }
            }
        }

        // Clean up old directory: remove data files (keep pointer.json if it's the default dir)
        let isDefaultDir = oldDir == defaultDataDirectory
        if isDefaultDir {
            // Only remove data files, keep pointer.json
            let filesToClean = ["scriptoria.db", "scriptoria.db-wal", "scriptoria.db-shm",
                                "config.json", "config.json.bak",
                                "scripts.json", "scripts.json.bak",
                                "schedules.json", "schedules.json.bak"]
            for file in filesToClean {
                try? fm.removeItem(atPath: "\(oldDir)/\(file)")
            }
            // Remove subdirectories and legacy directories
            for dir in ["db", "scripts", "history", "history.bak"] {
                try? fm.removeItem(atPath: "\(oldDir)/\(dir)")
            }
            // Remove script files from root
            if let files = try? fm.contentsOfDirectory(atPath: oldDir) {
                for file in files where file.hasSuffix(".sh") || file.hasSuffix(".py") || file.hasSuffix(".rb") || file.hasSuffix(".js") || file.hasSuffix(".zsh") {
                    try? fm.removeItem(atPath: "\(oldDir)/\(file)")
                }
            }
        }
    }

    /// Save config to SQLite and update the pointer
    public func save() throws {
        // Ensure data directory exists
        if !FileManager.default.fileExists(atPath: dataDirectory) {
            try FileManager.default.createDirectory(
                atPath: dataDirectory, withIntermediateDirectories: true
            )
        }

        // Write settings to SQLite
        let db = try DatabaseManager(directory: dataDirectory)
        try db.setConfig(key: "notifyOnCompletion", value: notifyOnCompletion ? "true" : "false")
        try db.setConfig(key: "showRunningIndicator", value: showRunningIndicator ? "true" : "false")
        try db.setConfig(key: "dataDirectory", value: dataDirectory)

        // Update pointer so CLI/App can find us
        try Config.savePointer(dataDirectory: dataDirectory)
    }
}
