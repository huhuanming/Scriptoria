import ArgumentParser
import Foundation
import ScriptoriaCore

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search scripts by keyword"
    )

    @Argument(help: "Search query")
    var query: String

    func run() async throws {
        let store = ScriptStore()
        try await store.load()

        let results = store.search(query: query)

        if results.isEmpty {
            print("No scripts matching \"\(query)\"")
            return
        }

        print("\n  Found \(results.count) script(s) matching \"\(query)\"\n")

        for script in results {
            let shortId = String(script.id.uuidString.prefix(8))
            print("  • \(script.title) (\(shortId))")
            if !script.description.isEmpty {
                print("    \(script.description)")
            }
            print("    \(script.path)")
            print()
        }
    }
}
