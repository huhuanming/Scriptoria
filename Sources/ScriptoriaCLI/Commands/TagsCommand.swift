import ArgumentParser
import Foundation
import ScriptoriaCore

struct TagsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tags",
        abstract: "Manage tags",
        subcommands: [
            TagsList.self,
            TagsAdd.self,
            TagsRemove.self,
        ],
        defaultSubcommand: TagsList.self
    )
}

// MARK: - List

struct TagsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all tags"
    )

    func run() async throws {
        let store = ScriptStore.fromConfig()
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

// MARK: - Add

struct TagsAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add tags to a script"
    )

    @Argument(help: "Script title or ID")
    var script: String

    @Argument(help: "Tags to add (comma-separated)")
    var tags: String

    func run() async throws {
        let store = ScriptStore.fromConfig()
        try await store.load()

        guard var found = findScript(store: store, identifier: script) else {
            print("❌ Script not found: \(script)")
            throw ExitCode.failure
        }

        let newTags = tags.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let added = newTags.filter { !found.tags.contains($0) }

        if added.isEmpty {
            print("All tags already exist on \(found.title).")
            return
        }

        found.tags.append(contentsOf: added)
        try await store.update(found)
        print("✅ Added tags to \(found.title): \(added.joined(separator: ", "))")
        print("   All tags: \(found.tags.joined(separator: ", "))")
    }
}

// MARK: - Remove

struct TagsRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove tags from a script"
    )

    @Argument(help: "Script title or ID")
    var script: String

    @Argument(help: "Tags to remove (comma-separated)")
    var tags: String

    func run() async throws {
        let store = ScriptStore.fromConfig()
        try await store.load()

        guard var found = findScript(store: store, identifier: script) else {
            print("❌ Script not found: \(script)")
            throw ExitCode.failure
        }

        let toRemove = tags.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let removed = toRemove.filter { found.tags.contains($0) }

        if removed.isEmpty {
            print("None of those tags exist on \(found.title).")
            return
        }

        found.tags.removeAll { toRemove.contains($0) }
        try await store.update(found)
        print("🗑  Removed tags from \(found.title): \(removed.joined(separator: ", "))")
        if found.tags.isEmpty {
            print("   No tags remaining.")
        } else {
            print("   Remaining tags: \(found.tags.joined(separator: ", "))")
        }
    }
}

// MARK: - Helper

private func findScript(store: ScriptStore, identifier: String) -> Script? {
    if let uuid = UUID(uuidString: identifier) {
        return store.get(id: uuid)
    }
    return store.get(title: identifier)
}
