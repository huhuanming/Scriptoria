import ArgumentParser
import Foundation
import ScriptoriaCore

struct PsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "List running scripts"
    )

    func run() throws {
        let store = ScriptStore.fromConfig()

        // Clean stale runs first
        ProcessManager.cleanStaleRuns(store: store)

        let runs = try store.fetchRunningRuns()

        if runs.isEmpty {
            print("No running scripts.")
            return
        }

        // Table header
        let header = String(format: "%-10s  %-20s  %-8s  %s", "RUN ID", "SCRIPT", "PID", "STARTED")
        print(header)
        print(String(repeating: "─", count: 60))

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        for run in runs {
            let idPrefix = String(run.id.uuidString.prefix(8))
            let title = String(run.scriptTitle.prefix(20))
            let pidStr = run.pid.map { String($0) } ?? "?"
            let started = formatter.string(from: run.startedAt)
            print(String(format: "%-10s  %-20s  %-8s  %s", idPrefix, title, pidStr, started))
        }
    }
}
