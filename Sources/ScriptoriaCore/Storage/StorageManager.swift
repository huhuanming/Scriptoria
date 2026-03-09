import Foundation

/// Manages file system operations for Scriptoria data
public actor StorageManager {
    public static let defaultBaseDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.scriptoria"
    }()

    private let baseDirectory: String
    private let fileManager = FileManager.default

    public var scriptsFile: String { "\(baseDirectory)/scripts.json" }
    public var schedulesFile: String { "\(baseDirectory)/schedules.json" }
    public var historyDirectory: String { "\(baseDirectory)/history" }
    public var configFile: String { "\(baseDirectory)/config.json" }

    public init(baseDirectory: String? = nil) {
        self.baseDirectory = baseDirectory ?? StorageManager.defaultBaseDirectory
    }

    /// Ensure all required directories exist
    public func ensureDirectories() throws {
        let dirs = [baseDirectory, historyDirectory]
        for dir in dirs {
            if !fileManager.fileExists(atPath: dir) {
                try fileManager.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true
                )
            }
        }
    }

    /// Read and decode a JSON file
    public func read<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    /// Encode and write a JSON file
    public func write<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Append a run record to the daily history file
    public func appendHistory(_ run: ScriptRun) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "\(historyDirectory)/\(formatter.string(from: run.startedAt)).jsonl"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(run)
        data.append(contentsOf: "\n".utf8)

        if fileManager.fileExists(atPath: filename) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filename))
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try data.write(to: URL(fileURLWithPath: filename))
        }
    }
}
