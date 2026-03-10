import ArgumentParser
import Darwin
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

    @Flag(name: .long, help: "Suppress completion notification")
    var noNotify: Bool = false

    @Flag(name: .long, help: "Scheduled run (less output)")
    var scheduled: Bool = false

    @Option(name: .long, help: "Override model for post-script agent run")
    var model: String?

    @Option(name: .long, help: "Additional prompt for the post-script agent")
    var agentPrompt: String?

    @Flag(name: .long, help: "Skip post-script agent stage")
    var skipAgent: Bool = false

    @Flag(name: .long, help: "Disable steering input while agent is running")
    var noSteer: Bool = false

    func run() async throws {
        let config = Config.load()
        let store = ScriptStore(config: config)
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

        // Duplicate prevention: check if already running
        if let existingRun = try store.fetchRunningRun(scriptId: script.id),
           let pid = existingRun.pid,
           ProcessManager.isRunning(pid: pid) {
            let idPrefix = String(existingRun.id.uuidString.prefix(8))
            print("⚠ Script '\(script.title)' is already running (run: \(idPrefix), pid: \(pid))")
            print("  Use 'scriptoria logs \(idPrefix) -f' to follow output")
            print("  Use 'scriptoria kill \(idPrefix)' to stop it")
            throw ExitCode.failure
        }

        print("▶ Running: \(script.title)")
        print("  Path: \(script.path)")
        print(String(repeating: "─", count: 50))

        let logManager = LogManager(config: config)

        // Insert a "running" record before execution starts
        let runId = UUID()
        var runRecord = ScriptRun(id: runId, scriptId: script.id, scriptTitle: script.title)
        try await store.saveRunHistory(runRecord)

        let runner = ScriptRunner()
        let capturedRunRecord = runRecord
        let result = try await runner.runStreaming(script, runId: runId, logManager: logManager, onStart: { pid in
            // Store PID in DB immediately
            var updated = capturedRunRecord
            updated.pid = pid
            try? store.updateRunHistorySync(updated)
        }) { text, isStderr in
            if isStderr {
                FileHandle.standardError.write(Data(text.utf8))
            } else {
                print(text, terminator: "")
            }
        }

        // Update run record with final result
        runRecord.output = result.output
        runRecord.errorOutput = result.errorOutput
        runRecord.exitCode = result.exitCode
        runRecord.finishedAt = result.finishedAt
        runRecord.status = result.status
        runRecord.pid = result.pid
        try await store.updateRunHistory(runRecord)

        // Update script stats
        try await store.recordRun(id: script.id, status: result.status)

        // Summary
        print(String(repeating: "─", count: 50))
        let statusIcon: String
        switch result.status {
        case .success: statusIcon = "✅"
        case .cancelled: statusIcon = "⚠️"
        default: statusIcon = "❌"
        }
        let duration = result.duration.map { String(format: "%.2fs", $0) } ?? "?"
        print("\(statusIcon) \(result.status.rawValue) (exit: \(result.exitCode ?? -1), duration: \(duration))")

        if result.status == .failure {
            if !noNotify {
                await NotificationManager.shared.notifyRunComplete(result)
            }
            throw ExitCode.failure
        }

        if !skipAgent {
            try await runAgentStage(
                script: script,
                scriptRun: runRecord,
                store: store,
                config: config
            )
        }

        // Always notify unless --no-notify
        if !noNotify {
            await NotificationManager.shared.notifyRunComplete(result)
        }
    }

    private func runAgentStage(
        script: Script,
        scriptRun: ScriptRun,
        store: ScriptStore,
        config: Config
    ) async throws {
        let taskName = script.agentTaskName.isEmpty ? script.title : script.agentTaskName
        let selectedModel = resolveModel(for: script)
        let memoryManager = MemoryManager(config: config)
        let workspaceMemory = memoryManager.readWorkspaceMemory(taskId: script.agentTaskId, taskName: taskName)
        let skillContent = readFileIfExists(path: script.skill)

        let developerInstructions = PostScriptAgentRunner.buildDeveloperInstructions(
            skillContent: clippedText(skillContent, max: 40_000),
            workspaceMemory: clippedText(workspaceMemory, max: 40_000)
        )

        var prompt = PostScriptAgentRunner.buildInitialPrompt(
            taskName: taskName,
            script: script,
            scriptRun: scriptRun
        )
        if let agentPrompt, !agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nAdditional user instruction:\n\(agentPrompt)\n"
        }

        let workingDirectory = URL(fileURLWithPath: script.path).deletingLastPathComponent().path
        print("\n🤖 Starting agent task: \(taskName)")
        print("   Model: \(selectedModel)")
        print(String(repeating: "─", count: 50))

        let session = try await PostScriptAgentRunner.launch(
            options: PostScriptAgentLaunchOptions(
                workingDirectory: workingDirectory,
                model: selectedModel,
                userPrompt: prompt,
                developerInstructions: developerInstructions
            ),
            onEvent: { event in
                switch event.kind {
                case .agentMessage, .commandOutput, .info:
                    print(event.text, terminator: "")
                case .error:
                    FileHandle.standardError.write(Data(event.text.utf8))
                }
            }
        )

        var agentRun = AgentRun(
            scriptId: script.id,
            scriptRunId: scriptRun.id,
            taskId: script.agentTaskId,
            taskName: taskName,
            model: selectedModel,
            threadId: await session.threadId,
            turnId: await session.turnId
        )
        try await store.saveAgentRun(agentRun)

        var steerTask: Task<Void, Never>?
        if shouldEnableSteer {
            print("\n[steer] Enter text to guide the running agent. Use /interrupt to stop.")
            steerTask = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    guard let line = readLine(strippingNewline: true) else {
                        break
                    }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    do {
                        if trimmed == "/interrupt" {
                            try await session.interrupt()
                            break
                        } else {
                            try await session.steer(trimmed)
                        }
                    } catch {
                        FileHandle.standardError.write(Data("[steer-error] \(error.localizedDescription)\n".utf8))
                    }
                }
            }
        }

        let agentResult = try await session.waitForCompletion()
        steerTask?.cancel()

        agentRun.threadId = agentResult.threadId
        agentRun.turnId = agentResult.turnId
        agentRun.status = agentResult.status
        agentRun.finishedAt = agentResult.finishedAt
        agentRun.finalMessage = agentResult.finalMessage
        agentRun.output = agentResult.output

        let taskMemoryPath = try memoryManager.writeTaskMemory(
            taskId: script.agentTaskId,
            taskName: taskName,
            script: script,
            scriptRun: scriptRun,
            agentResult: agentResult
        )
        agentRun.taskMemoryPath = taskMemoryPath
        try await store.updateAgentRun(agentRun)

        print(String(repeating: "─", count: 50))
        let duration = agentResult.finishedAt.timeIntervalSince(agentResult.startedAt)
        print("🤖 Agent \(agentResult.status.rawValue) · \(String(format: "%.2fs", duration))")
        print("📘 Task Memory: \(taskMemoryPath)")

        if agentResult.status == .failed {
            throw ExitCode.failure
        }
    }

    private var shouldEnableSteer: Bool {
        !scheduled && !noSteer && isatty(fileno(stdin)) == 1
    }

    private func resolveModel(for script: Script) -> String {
        if let model {
            let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }

        let defaultModel = script.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if scheduled {
            return defaultModel.isEmpty ? "gpt-5.3-codex" : defaultModel
        }

        let fallback = defaultModel.isEmpty ? "gpt-5.3-codex" : defaultModel
        if isatty(fileno(stdin)) == 1 {
            print("Model [\(fallback)]: ", terminator: "")
            if let input = readLine(strippingNewline: true)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !input.isEmpty {
                return input
            }
        }
        return fallback
    }

    private func readFileIfExists(path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? String(contentsOfFile: trimmed, encoding: .utf8)
    }

    private func clippedText(_ text: String?, max: Int) -> String? {
        guard let text else { return nil }
        if text.count <= max { return text }
        return String(text.prefix(max)) + "\n\n[truncated]"
    }
}
