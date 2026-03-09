import ArgumentParser
import Foundation
import ScriptoriaCore

struct RemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a script from Scriptoria"
    )

    @Argument(help: "Script title or ID")
    var identifier: String

    func run() async throws {
        let store = ScriptStore()
        try await store.load()

        let script: Script?
        if let uuid = UUID(uuidString: identifier) {
            script = store.get(id: uuid)
        } else {
            script = store.get(title: identifier)
        }

        guard let script else {
            print("❌ Script not found: \(identifier)")
            throw ExitCode.failure
        }

        try await store.remove(id: script.id)
        print("🗑  Removed: \(script.title)")
    }
}
