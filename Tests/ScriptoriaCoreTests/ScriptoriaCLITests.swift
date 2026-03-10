import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("CLI Command Coverage", .serialized)
struct ScriptoriaCLITests {
    @Test("common not-found and missing-arg failures")
    func testCommonFailurePaths() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-failures") { _ in
            let runMissing = try runCLI(arguments: ["run"])
            #expect(runMissing.exitCode != 0)

            let removeMissing = try runCLI(arguments: ["remove", "missing-script"])
            #expect(removeMissing.exitCode != 0)

            let memoryMissing = try runCLI(arguments: ["memory", "summarize"])
            #expect(memoryMissing.exitCode != 0)
            #expect(memoryMissing.stdout.contains("Please provide a script title/UUID or --task-id"))

            let scheduleDisableMissing = try runCLI(arguments: ["schedule", "disable", "deadbeef"])
            #expect(scheduleDisableMissing.exitCode != 0)
        }
    }

    @Test("add/list/search/remove lifecycle")
    func testScriptLifecycleCommands() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-lifecycle") { workspace in
            let scriptPath = try workspace.makeScript(
                name: "deploy.sh",
                content: "#!/bin/sh\necho deploy-ok\n"
            )
            let skillPath = try workspace.makeFile(relativePath: "skills/skill.md", content: "# skill")

            let add = try runCLI(arguments: [
                "add", scriptPath,
                "--title", "Deploy",
                "--description", "Deploy script",
                "--tags", "deploy,prod",
                "--skill", skillPath,
                "--task-name", "DeployTask",
                "--default-model", "gpt-test"
            ])
            #expect(add.exitCode == 0)
            #expect(add.stdout.contains("Added script: Deploy"))

            let list = try runCLI(arguments: ["list"])
            #expect(list.exitCode == 0)
            #expect(list.stdout.contains("Deploy"))
            #expect(list.stdout.contains("DeployTask"))
            #expect(list.stdout.contains("model: gpt-test"))

            let search = try runCLI(arguments: ["search", "deploy"])
            #expect(search.exitCode == 0)
            #expect(search.stdout.contains("Deploy"))

            let remove = try runCLI(arguments: ["remove", "Deploy"])
            #expect(remove.exitCode == 0)
            #expect(remove.stdout.contains("Removed: Deploy"))

            let listAfter = try runCLI(arguments: ["list"])
            #expect(listAfter.exitCode == 0)
            #expect(listAfter.stdout.contains("No scripts found."))
        }
    }

    @Test("add command failures")
    func testAddCommandFailures() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-add-failure") { workspace in
            let missing = try runCLI(arguments: ["add", "/tmp/does-not-exist.sh"])
            #expect(missing.exitCode != 0)
            #expect(missing.stdout.contains("File not found"))

            let scriptPath = try workspace.makeScript(name: "ok.sh", content: "#!/bin/sh\necho ok\n")
            let missingSkill = try runCLI(arguments: ["add", scriptPath, "--skill", "/tmp/skill-not-exist.md"])
            #expect(missingSkill.exitCode != 0)
            #expect(missingSkill.stdout.contains("Skill file not found"))
        }
    }

    @Test("tags list/add/remove")
    func testTagsCommands() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-tags") { workspace in
            let scriptPath = try workspace.makeScript(name: "taggable.sh", content: "#!/bin/sh\necho tags\n")
            _ = try runCLI(arguments: ["add", scriptPath, "--title", "Taggable", "--tags", "one"])

            let addTags = try runCLI(arguments: ["tags", "add", "Taggable", "two,three"])
            #expect(addTags.exitCode == 0)
            #expect(addTags.stdout.contains("Added tags"))

            let addDuplicate = try runCLI(arguments: ["tags", "add", "Taggable", "two"])
            #expect(addDuplicate.exitCode == 0)
            #expect(addDuplicate.stdout.contains("already exist"))

            let listTags = try runCLI(arguments: ["tags", "list"])
            #expect(listTags.exitCode == 0)
            #expect(listTags.stdout.contains("one"))
            #expect(listTags.stdout.contains("two"))

            let removeTag = try runCLI(arguments: ["tags", "remove", "Taggable", "one"])
            #expect(removeTag.exitCode == 0)
            #expect(removeTag.stdout.contains("Removed tags"))

            let removeMissing = try runCLI(arguments: ["tags", "remove", "Taggable", "not-there"])
            #expect(removeMissing.exitCode == 0)
            #expect(removeMissing.stdout.contains("None of those tags exist"))

            let store = ScriptStore.fromConfig()
            try await store.load()
            let script = try #require(store.get(title: "Taggable"))
            #expect(Set(script.tags) == Set(["two", "three"]))
        }
    }

    @Test("config show and set-dir")
    func testConfigCommands() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-config") { workspace in
            let initial = try runCLI(arguments: ["config", "show"])
            #expect(initial.exitCode == 0)
            #expect(initial.stdout.contains(workspace.defaultDataDir.path))

            let newDataDir = workspace.rootURL.appendingPathComponent("custom-data").path
            let setDir = try runCLI(arguments: ["config", "set-dir", newDataDir])
            #expect(setDir.exitCode == 0)
            #expect(setDir.stdout.contains("Data directory set to"))

            let loaded = Config.load()
            #expect(loaded.dataDirectory == newDataDir)

            let show = try runCLI(arguments: ["config", "show"])
            #expect(show.exitCode == 0)
            #expect(show.stdout.contains(newDataDir))
        }
    }

    @Test("run command success with skip-agent")
    func testRunCommandSuccess() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-run-success") { workspace in
            let scriptPath = try workspace.makeScript(name: "ok.sh", content: "#!/bin/sh\necho run-ok\n")
            let add = try runCLI(arguments: ["add", scriptPath, "--title", "RunOK"])
            #expect(add.exitCode == 0)

            let run = try runCLI(arguments: ["run", "RunOK", "--skip-agent", "--no-notify", "--no-steer"])
            #expect(run.exitCode == 0)
            #expect(run.stdout.contains("success"))
            #expect(run.stdout.contains("run-ok"))

            let store = ScriptStore.fromConfig()
            try await store.load()
            let script = try #require(store.get(title: "RunOK"))
            let history = try store.fetchRunHistory(scriptId: script.id, limit: 5)
            let latest = try #require(history.first)
            #expect(latest.status == .success)
            #expect(latest.exitCode == 0)
            #expect(script.runCount == 1)
        }
    }

    @Test("run command failure")
    func testRunCommandFailure() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-run-failure") { workspace in
            let scriptPath = try workspace.makeScript(
                name: "fail.sh",
                content: "#!/bin/sh\necho fail-msg\nexit 7\n"
            )
            let add = try runCLI(arguments: ["add", scriptPath, "--title", "RunFail"])
            #expect(add.exitCode == 0)

            let run = try runCLI(arguments: ["run", "RunFail", "--skip-agent", "--no-notify", "--no-steer"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("fail-msg"))

            let store = ScriptStore.fromConfig()
            try await store.load()
            let script = try #require(store.get(title: "RunFail"))
            let history = try store.fetchRunHistory(scriptId: script.id, limit: 1)
            let latest = try #require(history.first)
            #expect(latest.status == .failure)
            #expect(latest.exitCode == 7)
        }
    }

    @Test("run command duplicate process protection")
    func testRunCommandDuplicateProtection() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-run-dup") { workspace in
            let scriptPath = try workspace.makeScript(name: "dup.sh", content: "#!/bin/sh\necho dup\n")
            _ = try runCLI(arguments: ["add", scriptPath, "--title", "DupScript"])

            let store = ScriptStore.fromConfig()
            try await store.load()
            let script = try #require(store.get(title: "DupScript"))
            let running = ScriptRun(
                scriptId: script.id,
                scriptTitle: script.title,
                status: .running,
                pid: getpid()
            )
            try await store.saveRunHistory(running)

            let run = try runCLI(arguments: ["run", "DupScript", "--skip-agent", "--no-notify"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("already running"))
        }
    }

    @Test("run command agent stage + memory")
    func testRunCommandAgentStage() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-agent") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "complete"
            ]) {
                let scriptPath = try workspace.makeScript(name: "agent.sh", content: "#!/bin/sh\necho agent-script\n")
                let skillPath = try workspace.makeFile(relativePath: "skills/agent-skill.md", content: "# agent skill")
                _ = try runCLI(arguments: [
                    "add", scriptPath,
                    "--title", "AgentScript",
                    "--skill", skillPath,
                    "--task-name", "AgentTask",
                    "--default-model", "gpt-default"
                ])

                let run = try runCLI(
                    arguments: ["run", "AgentScript", "--no-notify", "--no-steer", "--model", "gpt-override"],
                    timeout: 20
                )
                #expect(run.exitCode == 0)
                #expect(run.timedOut == false)
                #expect(run.stdout.contains("Starting agent task"))
                #expect(run.stdout.contains("agent delta"))
                #expect(run.stdout.contains("Task Memory"))

                let store = ScriptStore.fromConfig()
                try await store.load()
                let script = try #require(store.get(title: "AgentScript"))
                let latest = try #require(try store.fetchLatestAgentRun(scriptId: script.id))
                #expect(latest.status == .completed)
                #expect(latest.model == "gpt-override")
                let taskMemoryPath = try #require(latest.taskMemoryPath)
                #expect(FileManager.default.fileExists(atPath: taskMemoryPath))
                #expect(taskMemoryPath.contains("/memory/AgentTask/task/"))
            }
        }
    }

    @Test("memory summarize by script and task-id")
    func testMemorySummarizeCommand() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-memory") { workspace in
            let scriptPath = try workspace.makeScript(name: "memory.sh", content: "#!/bin/sh\necho memory\n")
            _ = try runCLI(arguments: ["add", scriptPath, "--title", "MemoryScript", "--task-name", "MemoryTask"])

            let store = ScriptStore.fromConfig()
            try await store.load()
            let script = try #require(store.get(title: "MemoryScript"))
            let profile = try #require(try store.fetchAgentProfile(scriptId: script.id))

            let memory = MemoryManager(config: Config.load())
            let run = ScriptRun(
                scriptId: script.id,
                scriptTitle: script.title,
                finishedAt: Date(),
                status: .success,
                exitCode: 0,
                output: "stdout"
            )
            let agent = AgentExecutionResult(
                threadId: "thread-1",
                turnId: "turn-1",
                model: "gpt",
                startedAt: Date().addingTimeInterval(-1),
                finishedAt: Date(),
                status: .completed,
                finalMessage: "done",
                output: "out"
            )
            _ = try memory.writeTaskMemory(taskId: profile.id, taskName: profile.taskName, script: script, scriptRun: run, agentResult: agent)
            _ = try memory.writeTaskMemory(taskId: profile.id, taskName: profile.taskName, script: script, scriptRun: run, agentResult: agent)

            let summarizeByScript = try runCLI(arguments: ["memory", "summarize", "MemoryScript"])
            #expect(summarizeByScript.exitCode == 0)
            #expect(summarizeByScript.stdout.contains("Workspace memory updated"))

            let summarizeByTask = try runCLI(arguments: ["memory", "summarize", "--task-id", "\(profile.id)"])
            #expect(summarizeByTask.exitCode == 0)

            let workspacePath = memory.workspacePath(taskId: profile.id, taskName: profile.taskName)
            #expect(FileManager.default.fileExists(atPath: workspacePath))
        }
    }

    @Test("schedule command family")
    func testScheduleCommands() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-schedule") { workspace in
            let scriptPath = try workspace.makeScript(name: "schedule.sh", content: "#!/bin/sh\necho schedule\n")
            _ = try runCLI(arguments: ["add", scriptPath, "--title", "Sched"])

            let fake = try workspace.makeFakeLaunchctl()
            try await withEnvironment([
                "SCRIPTORIA_LAUNCHCTL_PATH": fake.path,
                "SCRIPTORIA_LAUNCH_AGENTS_DIR": fake.agentsDir,
                "SCRIPTORIA_FAKE_LAUNCHCTL_LOG": fake.logPath
            ]) {
                let every = try runCLI(arguments: ["schedule", "add", "Sched", "--every", "5"])
                #expect(every.exitCode == 0)
                let daily = try runCLI(arguments: ["schedule", "add", "Sched", "--daily", "09:30"])
                #expect(daily.exitCode == 0)
                let weekly = try runCLI(arguments: ["schedule", "add", "Sched", "--weekly", "mon,wed@10:15"])
                #expect(weekly.exitCode == 0)

                let invalid = try runCLI(arguments: ["schedule", "add", "Sched", "--daily", "0930"])
                #expect(invalid.exitCode != 0)

                let list = try runCLI(arguments: ["schedule", "list"])
                #expect(list.exitCode == 0)
                #expect(list.stdout.contains("SCHEDULED TASKS"))

                let scheduleStore = ScheduleStore.fromConfig()
                try await scheduleStore.load()
                let first = try #require(scheduleStore.all().first)
                let idPrefix = String(first.id.uuidString.prefix(8))

                let disable = try runCLI(arguments: ["schedule", "disable", idPrefix])
                #expect(disable.exitCode == 0)
                let enable = try runCLI(arguments: ["schedule", "enable", idPrefix])
                #expect(enable.exitCode == 0)
                let remove = try runCLI(arguments: ["schedule", "remove", idPrefix])
                #expect(remove.exitCode == 0)

                let log = (try? String(contentsOfFile: fake.logPath, encoding: .utf8)) ?? ""
                #expect(log.contains("load"))
                #expect(log.contains("unload"))
            }
        }
    }

    @Test("ps/logs/kill commands")
    func testPsLogsKillCommands() async throws {
        try await withTestWorkspace(prefix: "scriptoria-cli-process") { workspace in
            let scriptPath = try workspace.makeScript(name: "process.sh", content: "#!/bin/sh\necho process\n")
            _ = try runCLI(arguments: ["add", scriptPath, "--title", "ProcScript"])

            let store = ScriptStore.fromConfig()
            try await store.load()
            let script = try #require(store.get(title: "ProcScript"))

            let psEmpty = try runCLI(arguments: ["ps"])
            #expect(psEmpty.exitCode == 0)
            #expect(psEmpty.stdout.contains("No running scripts."))

            let finishedRun = ScriptRun(
                scriptId: script.id,
                scriptTitle: script.title,
                finishedAt: Date(),
                status: .success,
                exitCode: 0,
                output: "db-out-1\ndb-out-2\n",
                errorOutput: "db-err\n"
            )
            try await store.saveRunHistory(finishedRun)

            let logs = try runCLI(arguments: ["logs", String(finishedRun.id.uuidString.prefix(8))])
            #expect(logs.exitCode == 0)
            #expect(logs.stdout.contains("db-out-1"))
            #expect(logs.stdout.contains("db-err"))

            let followFinished = try runCLI(arguments: ["logs", String(finishedRun.id.uuidString.prefix(8)), "--follow"])
            #expect(followFinished.exitCode == 0)
            #expect(followFinished.stdout.contains("no effect"))

            let logManager = LogManager(config: Config.load())
            logManager.append("line-1\nline-2\n", to: finishedRun.id)
            let tail = try runCLI(arguments: ["logs", String(finishedRun.id.uuidString.prefix(8)), "--tail", "2"])
            #expect(tail.exitCode == 0)
            #expect(tail.stdout.contains("line-2"))

            let missingLogs = try runCLI(arguments: ["logs", "UNKNOWN"])
            #expect(missingLogs.exitCode != 0)

            var staleRun = ScriptRun(
                scriptId: script.id,
                scriptTitle: script.title,
                status: .running,
                pid: 999_999
            )
            try await store.saveRunHistory(staleRun)

            let psCleanup = try runCLI(arguments: ["ps"])
            #expect(psCleanup.exitCode == 0)
            staleRun = try #require(try store.fetchScriptRun(id: staleRun.id))
            #expect(staleRun.status == .failure)

            let killStale = try runCLI(arguments: ["kill", String(staleRun.id.uuidString.prefix(8))])
            #expect(killStale.exitCode != 0)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 30"]
            try process.run()

            let liveRun = ScriptRun(
                scriptId: script.id,
                scriptTitle: script.title,
                status: .running,
                pid: process.processIdentifier
            )
            try await store.saveRunHistory(liveRun)

            let killLive = try runCLI(arguments: ["kill", String(liveRun.id.uuidString.prefix(8))])
            #expect(killLive.exitCode == 0)
            waitForProcessToExit(process.processIdentifier)

            let updatedLiveRun = try #require(try store.fetchScriptRun(id: liveRun.id))
            #expect(updatedLiveRun.status == .cancelled)
        }
    }
}
