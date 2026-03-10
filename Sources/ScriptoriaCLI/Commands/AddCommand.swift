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

    @Option(name: .long, help: "Path to a skill file for AI agents")
    var skill: String?

    @Option(name: .long, help: "Task name for post-script agent runs and memory")
    var taskName: String?

    @Option(name: .long, help: "Default model for post-script agent runs")
    var defaultModel: String?

    func run() async throws {
        let store = ScriptStore.fromConfig()
        try await store.load()

        // Resolve path
        let resolvedPath = Self.resolvePath(path)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            print("❌ File not found: \(resolvedPath)")
            throw ExitCode.failure
        }

        // Resolve skill path
        var resolvedSkill = ""
        if let skill = skill {
            let skillPath = Self.resolvePath(skill)
            guard FileManager.default.fileExists(atPath: skillPath) else {
                print("❌ Skill file not found: \(skillPath)")
                throw ExitCode.failure
            }
            resolvedSkill = skillPath
        }

        // Parse interpreter
        let interp = Interpreter(rawValue: interpreter) ?? .auto

        // Parse tags
        let tagList = tags?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? []

        // Generate title from filename if not provided
        let scriptTitle = title ?? URL(fileURLWithPath: resolvedPath).deletingPathExtension().lastPathComponent
        let resolvedTaskName = taskName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTaskName = (resolvedTaskName?.isEmpty == false) ? resolvedTaskName! : scriptTitle

        let script = Script(
            title: scriptTitle,
            description: description,
            path: resolvedPath,
            skill: resolvedSkill,
            agentTaskName: finalTaskName,
            defaultModel: AgentRuntimeCatalog.normalizeModel(defaultModel),
            interpreter: interp,
            tags: tagList
        )

        try await store.add(script)
        print("✅ Added script: \(script.title)")
        print("   ID: \(script.id)")
        print("   Path: \(script.path)")
        if !resolvedSkill.isEmpty {
            print("   Skill: \(resolvedSkill)")
        }
        print("   Task: \(script.agentTaskName)")
        if !script.defaultModel.isEmpty {
            print("   Default Model: \(script.defaultModel)")
        }
        if !tagList.isEmpty {
            print("   Tags: \(tagList.joined(separator: ", "))")
        }
    }

    private static func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        } else if path.hasPrefix("~") {
            return NSString(string: path).expandingTildeInPath
        } else {
            return FileManager.default.currentDirectoryPath + "/" + path
        }
    }
}
