import ArgumentParser
import Foundation
import ScriptoriaCore

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "View or update Scriptoria configuration",
        subcommands: [
            ShowConfig.self,
            SetDataDir.self,
            UseICloud.self,
        ],
        defaultSubcommand: ShowConfig.self
    )
}

struct ShowConfig: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show current configuration"
    )

    func run() async throws {
        let config = Config.load()
        print("\n  Scriptoria Configuration\n")
        print("  Data directory:    \(config.dataDirectory)")
        print("  Notify on finish:  \(config.notifyOnCompletion)")
        print("  Running indicator: \(config.showRunningIndicator)")
        print("  Config file:       \(Config.configFilePath)")
        print()
    }
}

struct SetDataDir: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-dir",
        abstract: "Set the data storage directory"
    )

    @Argument(help: "Path to data directory")
    var path: String

    func run() async throws {
        let resolvedPath: String
        if path.hasPrefix("~") {
            resolvedPath = NSString(string: path).expandingTildeInPath
        } else if path.hasPrefix("/") {
            resolvedPath = path
        } else {
            resolvedPath = FileManager.default.currentDirectoryPath + "/" + path
        }

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: resolvedPath) {
            try FileManager.default.createDirectory(
                atPath: resolvedPath, withIntermediateDirectories: true
            )
        }

        var config = Config.load()
        config.dataDirectory = resolvedPath
        try config.save()

        print("✅ Data directory set to: \(resolvedPath)")
    }
}

struct UseICloud: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use-icloud",
        abstract: "Store data in iCloud Drive"
    )

    func run() async throws {
        let icloudPath = Config.iCloudDataDirectory

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: icloudPath) {
            try FileManager.default.createDirectory(
                atPath: icloudPath, withIntermediateDirectories: true
            )
        }

        var config = Config.load()
        config.dataDirectory = icloudPath
        try config.save()

        print("✅ Data directory set to iCloud: \(icloudPath)")
    }
}
