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

    @Flag(name: .long, help: "Send notification on completion")
    var notify: Bool = false

    func run() async throws {
        let store = ScriptStore()
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

        print("▶ Running: \(script.title)")
        print("  Path: \(script.path)")
        print(String(repeating: "─", count: 50))

        let runner = ScriptRunner()
        let result = try await runner.run(script)

        // Print output
        if !result.output.isEmpty {
            print(result.output)
        }
        if !result.errorOutput.isEmpty {
            print("STDERR:", result.errorOutput)
        }

        // Update run record
        try await store.recordRun(id: script.id, status: result.status)
        try await store.saveRunHistory(result)

        // Summary
        print(String(repeating: "─", count: 50))
        let icon = result.status == .success ? "✅" : "❌"
        let duration = result.duration.map { String(format: "%.2fs", $0) } ?? "?"
        print("\(icon) \(result.status.rawValue) (exit: \(result.exitCode ?? -1), duration: \(duration))")

        // Notification
        if notify {
            await NotificationManager.shared.notifyRunComplete(result)
        }

        if result.status == .failure {
            throw ExitCode.failure
        }
    }
}
