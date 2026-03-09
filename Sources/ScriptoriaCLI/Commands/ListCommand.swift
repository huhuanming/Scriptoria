import ArgumentParser
import Foundation
import ScriptoriaCore

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all managed scripts"
    )

    @Option(name: .shortAndLong, help: "Filter by tag")
    var tag: String?

    @Flag(name: .long, help: "Show only favorites")
    var favorites: Bool = false

    @Flag(name: .long, help: "Show recently run scripts")
    var recent: Bool = false

    func run() async throws {
        let store = ScriptStore.fromConfig()
        try await store.load()

        let scripts: [Script]
        if let tag {
            scripts = store.filter(tag: tag)
        } else if favorites {
            scripts = store.favorites()
        } else if recent {
            scripts = store.recentlyRun()
        } else {
            scripts = store.all()
        }

        if scripts.isEmpty {
            print("No scripts found.")
            return
        }

        print("\n  \("Scriptoria".uppercased()) — \(scripts.count) script(s)\n")
        print(String(repeating: "─", count: 72))

        for script in scripts {
            let status: String
            switch script.lastRunStatus {
            case .success: status = "✅"
            case .failure: status = "❌"
            case .running: status = "🔄"
            case .cancelled: status = "⏹"
            case nil: status = "⚪"
            }

            let fav = script.isFavorite ? "★ " : "  "
            print("  \(fav)\(status) \(script.title)")

            if !script.description.isEmpty {
                print("       \(script.description)")
            }

            if !script.skill.isEmpty {
                print("       🤖 Skill: \(script.skill)")
            }

            let shortId = String(script.id.uuidString.prefix(8))
            let tags = script.tags.isEmpty ? "" : " [\(script.tags.joined(separator: ", "))]"
            print("       \(shortId) · \(script.interpreter.rawValue)\(tags) · runs: \(script.runCount)")
            print(String(repeating: "─", count: 72))
        }
        print()
    }
}
