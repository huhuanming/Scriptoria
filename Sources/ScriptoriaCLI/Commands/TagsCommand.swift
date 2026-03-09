import ArgumentParser
import Foundation
import ScriptoriaCore

struct TagsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tags",
        abstract: "List all tags"
    )

    func run() async throws {
        let store = ScriptStore()
        try await store.load()

        let tags = store.allTags()

        if tags.isEmpty {
            print("No tags found.")
            return
        }

        print("\n  Tags (\(tags.count)):\n")
        for tag in tags {
            let count = store.filter(tag: tag).count
            print("  • \(tag) (\(count))")
        }
        print()
    }
}
