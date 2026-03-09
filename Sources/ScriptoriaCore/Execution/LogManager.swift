import Foundation

/// Manages persistent log files for script runs
public final class LogManager: Sendable {
    private let logsDirectory: String

    public init(logsDirectory: String) {
        self.logsDirectory = logsDirectory
        // Ensure logs directory exists
        let fm = FileManager.default
        if !fm.fileExists(atPath: logsDirectory) {
            try? fm.createDirectory(atPath: logsDirectory, withIntermediateDirectories: true)
        }
    }

    /// Convenience init from Config
    public convenience init(config: Config) {
        self.init(logsDirectory: config.logsDirectory)
    }

    /// Path to the log file for a given run
    public func logPath(for runId: UUID) -> String {
        "\(logsDirectory)/\(runId.uuidString).log"
    }

    /// Append text to a run's log file
    public func append(_ text: String, to runId: UUID) {
        let path = logPath(for: runId)
        guard let data = text.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// Read the entire log for a run
    public func readLog(for runId: UUID) -> String? {
        let path = logPath(for: runId)
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Read log from a byte offset, returning (text, newOffset)
    public func readLog(for runId: UUID, fromOffset offset: UInt64) -> (String, UInt64)? {
        let path = logPath(for: runId)
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (text, offset + UInt64(data.count))
    }

    /// Get the current file size (useful for checking if new data is available)
    public func logSize(for runId: UUID) -> UInt64 {
        let path = logPath(for: runId)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else {
            return 0
        }
        return size
    }

    /// Clean up log files older than the specified number of days
    public func cleanOldLogs(olderThan days: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logsDirectory) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)

        for file in files where file.hasSuffix(".log") {
            let path = "\(logsDirectory)/\(file)"
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modified = attrs[.modificationDate] as? Date,
               modified < cutoff {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}
