import ArgumentParser
import Foundation
import ScriptoriaCore

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a script by title or ID"
    )

    @Argument(help: "Script title or ID")
    var identifier: String?

    @Option(name: .long, help: "Script UUID")
    var id: String?

    @Flag(name: .long, help: "Suppress completion notification")
    var noNotify: Bool = false

    @Flag(name: .long, help: "Scheduled run (less output)")
    var scheduled: Bool = false

    func run() async throws {
        let config = Config.load()
        let store = ScriptStore(config: config)
        try await store.load()

        // Find the script
        let script: Script?
        if let id, let uuid = UUID(uuidString: id) {
            script = store.get(id: uuid)
        } else if let identifier {
            // Try as UUID first, then as title
            if let uuid = UUID(uuidString: identifier) {
                script = store.get(id: uuid)
            } else {
                script = store.get(title: identifier)
            }
        } else {
            print("❌ Please provide a script title or --id")
            throw ExitCode.failure
        }

        guard let script else {
            print("❌ Script not found")
            throw ExitCode.failure
        }

        // Duplicate prevention: check if already running
        if let existingRun = try store.fetchRunningRun(scriptId: script.id),
           let pid = existingRun.pid,
           ProcessManager.isRunning(pid: pid) {
            let idPrefix = String(existingRun.id.uuidString.prefix(8))
            print("⚠ Script '\(script.title)' is already running (run: \(idPrefix), pid: \(pid))")
            print("  Use 'scriptoria logs \(idPrefix) -f' to follow output")
            print("  Use 'scriptoria kill \(idPrefix)' to stop it")
            throw ExitCode.failure
        }

        print("▶ Running: \(script.title)")
        print("  Path: \(script.path)")
        print(String(repeating: "─", count: 50))

        let logManager = LogManager(config: config)

        // Insert a "running" record before execution starts
        let runId = UUID()
        var runRecord = ScriptRun(id: runId, scriptId: script.id, scriptTitle: script.title)
        try await store.saveRunHistory(runRecord)

        let runner = ScriptRunner()
        let capturedRunRecord = runRecord
        let result = try await runner.runStreaming(script, runId: runId, logManager: logManager, onStart: { pid in
            // Store PID in DB immediately
            var updated = capturedRunRecord
            updated.pid = pid
            try? store.updateRunHistorySync(updated)
        }) { text, isStderr in
            if isStderr {
                FileHandle.standardError.write(Data(text.utf8))
            } else {
                print(text, terminator: "")
            }
        }

        // Update run record with final result
        runRecord.output = result.output
        runRecord.errorOutput = result.errorOutput
        runRecord.exitCode = result.exitCode
        runRecord.finishedAt = result.finishedAt
        runRecord.status = result.status
        runRecord.pid = result.pid
        try await store.updateRunHistory(runRecord)

        // Update script stats
        try await store.recordRun(id: script.id, status: result.status)

        // Summary
        print(String(repeating: "─", count: 50))
        let statusIcon: String
        switch result.status {
        case .success: statusIcon = "✅"
        case .cancelled: statusIcon = "⚠️"
        default: statusIcon = "❌"
        }
        let duration = result.duration.map { String(format: "%.2fs", $0) } ?? "?"
        print("\(statusIcon) \(result.status.rawValue) (exit: \(result.exitCode ?? -1), duration: \(duration))")

        // Always notify unless --no-notify
        if !noNotify {
            await NotificationManager.shared.notifyRunComplete(result)
        }

        if result.status == .failure {
            throw ExitCode.failure
        }
    }
}
