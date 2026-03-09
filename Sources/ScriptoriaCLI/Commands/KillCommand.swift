import ArgumentParser
import Foundation
import ScriptoriaCore

struct KillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Kill a running script"
    )

    @Argument(help: "Run ID (prefix match)")
    var runId: String

    @Flag(name: .long, help: "Force kill (SIGKILL instead of SIGTERM)")
    var force: Bool = false

    func run() throws {
        let store = ScriptStore.fromConfig()

        // Find matching run among running tasks
        let runs = try store.fetchRunningRuns()
        let prefix = runId.uppercased()
        let matches = runs.filter { $0.id.uuidString.uppercased().hasPrefix(prefix) }

        guard var matchedRun = matches.first else {
            print("❌ No running task found matching '\(runId)'")
            throw ExitCode.failure
        }

        if matches.count > 1 {
            print("⚠ Multiple matches, using most recent: \(String(matchedRun.id.uuidString.prefix(8)))")
        }

        guard let pid = matchedRun.pid else {
            print("❌ No PID recorded for run \(String(matchedRun.id.uuidString.prefix(8)))")
            throw ExitCode.failure
        }

        guard ProcessManager.isRunning(pid: pid) else {
            print("⚠ Process \(pid) is not running, marking as failed")
            matchedRun.status = .failure
            matchedRun.finishedAt = Date()
            try store.updateRunHistorySync(matchedRun)
            return
        }

        let signalName = force ? "SIGKILL" : "SIGTERM"
        if ProcessManager.terminate(pid: pid, force: force) {
            print("✅ Sent \(signalName) to process \(pid) (\(matchedRun.scriptTitle))")
            matchedRun.status = .cancelled
            matchedRun.finishedAt = Date()
            try store.updateRunHistorySync(matchedRun)
        } else {
            print("❌ Failed to send \(signalName) to process \(pid)")
            throw ExitCode.failure
        }
    }
}
