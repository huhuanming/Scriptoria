import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Core Behavior Coverage", .serialized)
struct ScriptoriaCoreBehaviorTests {
    @Test("config save/load and env override")
    func testConfigBehavior() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-config") { workspace in
            var config = Config.load()
            #expect(config.dataDirectory == workspace.defaultDataDir.path)

            config.notifyOnCompletion = false
            config.showRunningIndicator = false
            try config.save()

            let loaded = Config.load()
            #expect(loaded.notifyOnCompletion == false)
            #expect(loaded.showRunningIndicator == false)

            let overrideDir = workspace.rootURL.appendingPathComponent("override-data").path
            await withEnvironment(["SCRIPTORIA_DATA_DIR": overrideDir]) {
                let overridden = Config.load()
                #expect(overridden.dataDirectory == overrideDir)
            }
        }
    }

    @Test("agent runtime catalog detects providers from PATH")
    func testAgentRuntimeCatalogProviderDiscovery() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-agent-catalog") { workspace in
            _ = try workspace.makeExecutable(relativePath: "bin/codex", content: "#!/bin/sh\nexit 0\n")
            _ = try workspace.makeExecutable(relativePath: "bin/claude-adapter", content: "#!/bin/sh\nexit 0\n")
            _ = try workspace.makeExecutable(relativePath: "bin/kimi-adapter", content: "#!/bin/sh\nexit 0\n")

            let snapshot = AgentRuntimeCatalog.discover(
                environment: ["PATH": workspace.rootURL.appendingPathComponent("bin").path],
                homeDirectory: workspace.rootURL.path
            )

            #expect(snapshot.configuredProvider == .codex)
            #expect(snapshot.activeProvider?.isAvailable == true)
            #expect(snapshot.providers.contains(where: { $0.provider == .claude && $0.isAvailable }))
            #expect(snapshot.providers.contains(where: { $0.provider == .kimi && $0.isAvailable }))
            #expect(snapshot.models.contains(AgentRuntimeCatalog.defaultModel))
            #expect(snapshot.models.contains("claude-sonnet"))
            #expect(snapshot.models.contains("kimi-k2"))
        }
    }

    @Test("agent runtime catalog honors configured executable override")
    func testAgentRuntimeCatalogConfiguredExecutable() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-agent-configured") { workspace in
            let claudeAdapter = try workspace.makeExecutable(
                relativePath: "agents/claude-adapter",
                content: "#!/bin/sh\nexit 0\n"
            )

            let snapshot = AgentRuntimeCatalog.discover(
                environment: [
                    "SCRIPTORIA_CODEX_EXECUTABLE": claudeAdapter,
                    "PATH": workspace.rootURL.appendingPathComponent("bin").path
                ],
                homeDirectory: workspace.rootURL.path
            )

            #expect(snapshot.configuredProvider == .claude)
            #expect(snapshot.activeProvider?.resolvedPath == claudeAdapter)
            #expect(snapshot.models.contains("claude-sonnet"))
            #expect(AgentRuntimeCatalog.normalizeModel(nil) == AgentRuntimeCatalog.defaultModel)
            #expect(AgentRuntimeCatalog.normalizeModel("  ") == AgentRuntimeCatalog.defaultModel)
        }
    }

    @Test("script store + agent profile + run storage")
    func testScriptStoreAndAgentPersistence() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-store") { workspace in
            let store = ScriptStore(baseDirectory: workspace.defaultDataDir.path)
            try await store.load()

            let script = Script(
                title: "Core Script",
                description: "desc",
                path: "/tmp/core.sh",
                agentTaskName: "CoreTask",
                defaultModel: "gpt-core",
                interpreter: .bash,
                tags: ["core", "test"]
            )

            let inserted = try await store.add(script)
            #expect(inserted.agentTaskId != nil)
            #expect(store.get(id: inserted.id) != nil)

            let profile = try #require(try store.fetchAgentProfile(scriptId: inserted.id))
            #expect(profile.taskName == "CoreTask")
            #expect(profile.defaultModel == "gpt-core")

            var updated = inserted
            updated.agentTaskName = "CoreTaskV2"
            updated.defaultModel = "gpt-core-v2"
            updated.tags.append("extra")
            try await store.update(updated)

            let refreshedProfile = try #require(try store.fetchAgentProfile(scriptId: inserted.id))
            #expect(refreshedProfile.taskName == "CoreTaskV2")
            #expect(refreshedProfile.defaultModel == "gpt-core-v2")

            let now = Date()
            let run1 = ScriptRun(
                scriptId: inserted.id,
                scriptTitle: inserted.title,
                startedAt: now.addingTimeInterval(-5),
                finishedAt: now,
                status: .success,
                exitCode: 0
            )
            try await store.saveRunHistory(run1)
            let run2 = ScriptRun(
                scriptId: inserted.id,
                scriptTitle: inserted.title,
                startedAt: now.addingTimeInterval(-12),
                finishedAt: now.addingTimeInterval(-6),
                status: .failure,
                exitCode: 2
            )
            try await store.saveRunHistory(run2)
            try await store.recordRun(id: inserted.id, status: .success)

            let avg = try store.fetchAverageDuration(scriptId: inserted.id)
            #expect(avg != nil)
            let allAvg = try store.fetchAllAverageDurations()
            #expect(allAvg[inserted.id] != nil)

            var agentRun = AgentRun(
                scriptId: inserted.id,
                scriptRunId: run1.id,
                taskId: refreshedProfile.id,
                taskName: refreshedProfile.taskName,
                model: refreshedProfile.defaultModel,
                threadId: "thread-core",
                turnId: "turn-core"
            )
            try await store.saveAgentRun(agentRun)

            agentRun.status = .completed
            agentRun.finishedAt = Date()
            agentRun.finalMessage = "done"
            agentRun.output = "output"
            agentRun.taskMemoryPath = "/tmp/task-memory.md"
            try await store.updateAgentRun(agentRun)

            let latestAgent = try #require(try store.fetchLatestAgentRun(scriptId: inserted.id))
            #expect(latestAgent.status == .completed)
            #expect(latestAgent.finalMessage == "done")

            try await store.remove(id: inserted.id)
            #expect(store.get(id: inserted.id) == nil)
            #expect(try store.fetchAgentProfile(scriptId: inserted.id) == nil)
        }
    }

    @Test("legacy JSON migration to sqlite")
    func testLegacyMigration() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-migration") { workspace in
            let dataDir = workspace.defaultDataDir.path
            let scriptId = UUID()
            let scheduleId = UUID()
            let runId = UUID()
            let script = Script(
                id: scriptId,
                title: "Migrated Script",
                description: "legacy",
                path: "/tmp/migrated.sh",
                tags: ["legacy"]
            )
            let schedule = Schedule(id: scheduleId, scriptId: scriptId, type: .interval(300))
            let run = ScriptRun(
                id: runId,
                scriptId: scriptId,
                scriptTitle: script.title,
                startedAt: Date().addingTimeInterval(-2),
                finishedAt: Date(),
                status: .success,
                exitCode: 0,
                output: "legacy-output"
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let scriptsData = try encoder.encode([script])
            try scriptsData.write(to: URL(fileURLWithPath: "\(dataDir)/scripts.json"))

            let schedulesData = try encoder.encode([schedule])
            try schedulesData.write(to: URL(fileURLWithPath: "\(dataDir)/schedules.json"))

            let historyDir = URL(fileURLWithPath: dataDir).appendingPathComponent("history")
            try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
            let historyLine = String(data: try encoder.encode(run), encoding: .utf8)! + "\n"
            try historyLine.write(
                to: historyDir.appendingPathComponent("runs.jsonl"),
                atomically: true,
                encoding: .utf8
            )

            let db = try DatabaseManager(directory: dataDir)
            let migrated = try db.migrateFromJSONIfNeeded(directory: dataDir)
            #expect(migrated == true)

            let store = ScriptStore(baseDirectory: dataDir)
            try await store.load()
            #expect(store.get(id: scriptId) != nil)
            #expect(store.allTags().contains("legacy"))

            let scheduleStore = ScheduleStore(baseDirectory: dataDir)
            try await scheduleStore.load()
            #expect(scheduleStore.get(id: scheduleId) != nil)

            let runHistory = try store.fetchAllRunHistory(limit: 10)
            #expect(runHistory.contains(where: { $0.id == runId }))

            #expect(FileManager.default.fileExists(atPath: "\(dataDir)/scripts.json.bak"))
            #expect(FileManager.default.fileExists(atPath: "\(dataDir)/schedules.json.bak"))
            #expect(FileManager.default.fileExists(atPath: "\(dataDir)/history.bak"))
        }
    }

    @Test("log manager append/read/cleanup")
    func testLogManagerBehavior() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-log") { workspace in
            let logsDir = workspace.rootURL.appendingPathComponent("logs").path
            let logManager = LogManager(logsDirectory: logsDir)
            let runId = UUID()

            logManager.append("line-1\n", to: runId)
            logManager.append("line-2\n", to: runId)
            let full = logManager.readLog(for: runId)
            #expect(full?.contains("line-1") == true)
            #expect(logManager.logSize(for: runId) > 0)

            let part = logManager.readLog(for: runId, fromOffset: 0)
            #expect(part?.0.contains("line-2") == true)

            let path = logManager.logPath(for: runId)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-86400 * 10)],
                ofItemAtPath: path
            )
            logManager.cleanOldLogs(olderThan: 7)
            #expect(FileManager.default.fileExists(atPath: path) == false)
        }
    }

    @Test("script runner streaming and interpreter detection")
    func testScriptRunnerBehavior() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-runner") { workspace in
            let okPath = try workspace.makeScript(
                name: "stream.sh",
                content: "#!/bin/sh\necho stdout-msg\necho stderr-msg 1>&2\n"
            )
            let script = Script(title: "RunnerOK", path: okPath, interpreter: .sh)

            let runner = ScriptRunner()
            let streamed = OutputCollector()
            let result = try await runner.runStreaming(script) { text, isStderr in
                if isStderr {
                    streamed.appendStderr(text)
                } else {
                    streamed.appendStdout(text)
                }
            }

            #expect(result.status == .success)
            #expect(result.exitCode == 0)
            #expect(streamed.stdout.contains("stdout-msg"))
            #expect(streamed.stderr.contains("stderr-msg"))

            let failPath = try workspace.makeScript(
                name: "fail.sh",
                content: "#!/bin/sh\necho fail\nexit 4\n"
            )
            let failScript = Script(title: "RunnerFail", path: failPath, interpreter: .sh)
            let failResult = try await runner.run(failScript)
            #expect(failResult.status == .failure)
            #expect(failResult.exitCode == 4)

            let shebangPath = try workspace.makeScript(
                name: "shebang-script",
                content: "#!/usr/bin/env python3\nprint('x')\n",
                executable: false
            )
            #expect(runner.detectInterpreter(for: shebangPath) == .python3)
        }
    }

    @Test("process manager stale cleanup")
    func testProcessManagerCleanup() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-process") { workspace in
            let store = ScriptStore(baseDirectory: workspace.defaultDataDir.path)
            try await store.load()
            let script = try await store.add(Script(title: "Proc", path: "/tmp/proc.sh"))
            let run = ScriptRun(
                scriptId: script.id,
                scriptTitle: script.title,
                status: .running,
                pid: 999_999
            )
            try await store.saveRunHistory(run)

            ProcessManager.cleanStaleRuns(store: store)

            let refreshed = try #require(try store.fetchScriptRun(id: run.id))
            #expect(refreshed.status == .failure)
        }
    }

    @Test("memory manager write/read/summarize")
    func testMemoryManagerBehavior() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-memory") { workspace in
            let memory = MemoryManager(baseDirectory: workspace.rootURL.appendingPathComponent("memory").path)
            let script = Script(title: "Memory Script", path: "/tmp/memory.sh")
            let scriptRun = ScriptRun(
                scriptId: script.id,
                scriptTitle: script.title,
                finishedAt: Date(),
                status: .success,
                exitCode: 0,
                output: "ok"
            )

            let fixedFinishedAt = Date()
            let first = AgentExecutionResult(
                threadId: "t1",
                turnId: "u1",
                model: "m1",
                startedAt: Date().addingTimeInterval(-2),
                finishedAt: fixedFinishedAt,
                status: .completed,
                finalMessage: "first",
                output: "first-out"
            )
            let second = AgentExecutionResult(
                threadId: "t2",
                turnId: "u2",
                model: "m2",
                startedAt: Date().addingTimeInterval(-1),
                finishedAt: fixedFinishedAt,
                status: .failed,
                finalMessage: "",
                output: "second-out"
            )

            let p1 = try memory.writeTaskMemory(taskId: 1, taskName: "Task/Name", script: script, scriptRun: scriptRun, agentResult: first)
            let p2 = try memory.writeTaskMemory(taskId: 1, taskName: "Task/Name", script: script, scriptRun: scriptRun, agentResult: second)
            #expect(p1 != p2)
            #expect(FileManager.default.fileExists(atPath: p1))
            #expect(FileManager.default.fileExists(atPath: p2))
            #expect(p1.contains("/memory/Task-Name/task/"))

            let workspacePath = try memory.summarizeWorkspaceMemory(taskId: 1, taskName: "Task/Name")
            #expect(FileManager.default.fileExists(atPath: workspacePath))
            let workspaceText = try #require(memory.readWorkspaceMemory(taskId: 1, taskName: "Task/Name"))
            #expect(workspaceText.contains("Workspace Memory"))
            #expect(workspaceText.contains("Top Good Patterns"))
        }
    }

    @Test("schedule store activation and next-run calculation")
    func testScheduleStoreBehavior() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-schedule") { workspace in
            let fake = try workspace.makeFakeLaunchctl()
            try await withEnvironment([
                "SCRIPTORIA_LAUNCHCTL_PATH": fake.path,
                "SCRIPTORIA_LAUNCH_AGENTS_DIR": fake.agentsDir,
                "SCRIPTORIA_FAKE_LAUNCHCTL_LOG": fake.logPath
            ]) {
                let scriptStore = ScriptStore(baseDirectory: workspace.defaultDataDir.path)
                try await scriptStore.load()
                let script = try await scriptStore.add(Script(title: "ScheduleCore", path: "/tmp/schedule.sh"))

                let scheduleStore = ScheduleStore(baseDirectory: workspace.defaultDataDir.path)
                try await scheduleStore.load()

                let schedule = Schedule(scriptId: script.id, type: .interval(120))
                _ = try await scheduleStore.add(schedule)
                try await scheduleStore.activate(schedule)

                var activated = try #require(scheduleStore.get(id: schedule.id))
                #expect(activated.isEnabled == true)
                #expect(activated.nextRunAt != nil)

                try await scheduleStore.deactivate(activated)
                activated = try #require(scheduleStore.get(id: schedule.id))
                #expect(activated.isEnabled == false)

                try await scheduleStore.remove(id: schedule.id)
                #expect(scheduleStore.get(id: schedule.id) == nil)

                #expect(ScheduleStore.computeNextRun(for: .interval(60)) != nil)
                #expect(ScheduleStore.computeNextRun(for: .daily(hour: 9, minute: 0)) != nil)
                #expect(ScheduleStore.computeNextRun(for: .weekly(weekdays: [2, 4], hour: 10, minute: 30)) != nil)
            }
        }
    }

    @Test("post-script agent prompt and instruction builders")
    func testPostScriptAgentRunnerBehavior() async throws {
        try await withTestWorkspace(prefix: "scriptoria-core-agent") { workspace in
            let options = PostScriptAgentLaunchOptions(
                workingDirectory: workspace.rootURL.path,
                model: "gpt-test",
                userPrompt: "start",
                developerInstructions: "dev",
                codexExecutable: "codex-test"
            )
            #expect(options.codexExecutable == "codex-test")

            let instructions = PostScriptAgentRunner.buildDeveloperInstructions(
                skillContent: "# skill",
                workspaceMemory: "# workspace"
            )
            #expect(instructions.contains("Injected Skill"))
            #expect(instructions.contains("Workspace Memory"))

            let script = Script(title: "PromptScript", path: "/tmp/prompt.sh")
            let run = ScriptRun(scriptId: script.id, scriptTitle: script.title, status: .success, exitCode: 0, output: "o", errorOutput: "e")
            let prompt = PostScriptAgentRunner.buildInitialPrompt(taskName: "PromptTask", script: script, scriptRun: run)
            #expect(prompt.contains("Task Name: PromptTask"))
            #expect(prompt.contains("Script STDOUT"))
        }
    }

    @Test("agent input command parsing for cli/gui")
    func testAgentInputCommandParsing() {
        #expect(AgentCommandInput.parseCLI("  fix only lint  ") == .steer("fix only lint"))
        #expect(AgentCommandInput.parseCLI("/interrupt") == .interrupt)
        #expect(AgentCommandInput.parseCLI("   ") == nil)

        #expect(AgentCommandInput.from(mode: .prompt, input: "next step") == .steer("next step"))
        #expect(AgentCommandInput.from(mode: .interrupt, input: "ignored") == .interrupt)
        #expect(AgentCommandInput.from(mode: .prompt, input: "   ") == nil)
    }
}
