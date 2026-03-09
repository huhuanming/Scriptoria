import ArgumentParser
import Foundation
import ScriptoriaCore

struct LogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "View logs for a script run"
    )

    @Argument(help: "Run ID (prefix match)")
    var runId: String

    @Flag(name: .shortAndLong, help: "Follow live output")
    var follow: Bool = false

    @Option(name: .long, help: "Show last N lines")
    var tail: Int?

    func run() throws {
        let config = Config.load()
        let store = ScriptStore(config: config)
        let logManager = LogManager(config: config)

        // Find matching run by prefix
        let allRuns = try store.fetchAllRunHistory(limit: 500)
        let prefix = runId.uppercased()
        let matches = allRuns.filter { $0.id.uuidString.uppercased().hasPrefix(prefix) }

        guard let matchedRun = matches.first else {
            print("❌ No run found matching '\(runId)'")
            throw ExitCode.failure
        }

        if matches.count > 1 {
            print("⚠ Multiple matches, using most recent: \(String(matchedRun.id.uuidString.prefix(8)))")
        }

        // Try reading from log file first, fall back to DB output
        if let logContent = logManager.readLog(for: matchedRun.id) {
            if let tailLines = tail {
                let lines = logContent.split(separator: "\n", omittingEmptySubsequences: false)
                let start = max(0, lines.count - tailLines)
                for line in lines[start...] {
                    print(line)
                }
            } else {
                print(logContent, terminator: "")
            }
        } else if !matchedRun.output.isEmpty || !matchedRun.errorOutput.isEmpty {
            // Fall back to output stored in database
            let content = matchedRun.output + (matchedRun.errorOutput.isEmpty ? "" : "\n" + matchedRun.errorOutput)
            if let tailLines = tail {
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                let start = max(0, lines.count - tailLines)
                for line in lines[start...] {
                    print(line)
                }
            } else {
                print(content, terminator: "")
            }
        } else {
            print("(no output)")
        }

        // Follow mode: tail the log file
        if follow && matchedRun.status == .running {
            var offset = logManager.logSize(for: matchedRun.id)
            print("\n--- following \(String(matchedRun.id.uuidString.prefix(8))) (Ctrl+C to stop) ---")

            while true {
                if let (text, newOffset) = logManager.readLog(for: matchedRun.id, fromOffset: offset) {
                    print(text, terminator: "")
                    fflush(stdout)
                    offset = newOffset
                }

                // Check if process is still running
                if let pid = matchedRun.pid, !ProcessManager.isRunning(pid: pid) {
                    print("\n--- process exited ---")
                    break
                }

                Thread.sleep(forTimeInterval: 0.2)
            }
        } else if follow && matchedRun.status != .running {
            print("\n(run already finished, --follow has no effect)")
        }
    }
}
