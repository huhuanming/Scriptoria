import ArgumentParser
import Foundation
import ScriptoriaCore

struct AddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a new script to Scriptoria"
    )

    @Argument(help: "Path to the script file")
    var path: String

    @Option(name: .shortAndLong, help: "Title for the script")
    var title: String?

    @Option(name: .shortAndLong, help: "Description of the script")
    var description: String = ""

    @Option(name: .shortAndLong, help: "Interpreter to use (auto, bash, zsh, node, python3, etc.)")
    var interpreter: String = "auto"

    @Option(name: .long, help: "Comma-separated tags")
    var tags: String?

    func run() async throws {
        let store = ScriptStore()
        try await store.load()

        // Resolve path
        let resolvedPath: String
        if path.hasPrefix("/") {
            resolvedPath = path
        } else if path.hasPrefix("~") {
            resolvedPath = NSString(string: path).expandingTildeInPath
        } else {
            resolvedPath = FileManager.default.currentDirectoryPath + "/" + path
        }

        // Verify file exists
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            print("❌ File not found: \(resolvedPath)")
            throw ExitCode.failure
        }

        // Parse interpreter
        let interp = Interpreter(rawValue: interpreter) ?? .auto

        // Parse tags
        let tagList = tags?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? []

        // Generate title from filename if not provided
        let scriptTitle = title ?? URL(fileURLWithPath: resolvedPath).deletingPathExtension().lastPathComponent

        let script = Script(
            title: scriptTitle,
            description: description,
            path: resolvedPath,
            interpreter: interp,
            tags: tagList
        )

        try await store.add(script)
        print("✅ Added script: \(script.title)")
        print("   ID: \(script.id)")
        print("   Path: \(script.path)")
        if !tagList.isEmpty {
            print("   Tags: \(tagList.joined(separator: ", "))")
        }
    }
}
