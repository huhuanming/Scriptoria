import ArgumentParser
import Foundation
import ScriptoriaCore

struct MemoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Manage task/workspace memory",
        subcommands: [
            MemorySummarize.self
        ],
        defaultSubcommand: MemorySummarize.self
    )
}

struct MemorySummarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Summarize task memories into workspace memory"
    )

    @Argument(help: "Script title or UUID")
    var identifier: String?

    @Option(name: .long, help: "Script UUID")
    var id: String?

    @Option(name: .long, help: "Task profile ID (SQLite autoincrement id)")
    var taskId: Int?

    func run() async throws {
        let config = Config.load()
        let store = ScriptStore(config: config)
        try await store.load()
        let memoryManager = MemoryManager(config: config)

        let profile: ScriptAgentProfile?
        if let taskId {
            profile = try store.fetchAgentProfile(taskId: taskId)
        } else {
            guard let script = try resolveScript(store: store) else {
                print("❌ Script not found")
                throw ExitCode.failure
            }
            profile = try store.fetchAgentProfile(scriptId: script.id)
        }

        guard let profile else {
            print("❌ Task profile not found")
            throw ExitCode.failure
        }

        let path = try memoryManager.summarizeWorkspaceMemory(
            taskId: profile.id,
            taskName: profile.taskName
        )
        print("✅ Workspace memory updated")
        print("   Task: [\(profile.id)] \(profile.taskName)")
        print("   Path: \(path)")
    }

    private func resolveScript(store: ScriptStore) throws -> Script? {
        if let id, let uuid = UUID(uuidString: id) {
            return store.get(id: uuid)
        }

        guard let identifier else {
            print("❌ Please provide a script title/UUID or --task-id")
            throw ExitCode.failure
        }

        if let uuid = UUID(uuidString: identifier) {
            return store.get(id: uuid)
        }

        return store.get(title: identifier)
    }
}

