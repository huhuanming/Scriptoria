import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Execution M0", .serialized)
struct ExecutionM0Tests {
    @Test("ScriptRunner supports args/env/workingDirectory")
    func testScriptRunnerOptionsMapping() async throws {
        try await withTestWorkspace(prefix: "flow-m0-script-options") { workspace in
            let scriptPath = try workspace.makeScript(
                name: "inspect.sh",
                content: "#!/bin/sh\necho \"arg:$1\"\necho \"env:$FLAG\"\npwd\n"
            )
            let script = Script(title: "Inspect", path: scriptPath, interpreter: .sh)
            let customCwd = workspace.rootURL.appendingPathComponent("custom-cwd")
            try FileManager.default.createDirectory(at: customCwd, withIntermediateDirectories: true)

            let runner = ScriptRunner()
            let result = try await runner.run(
                script,
                options: .init(
                    args: ["hello"],
                    env: ["FLAG": "on"],
                    timeoutSec: 30,
                    workingDirectory: customCwd.path
                )
            )

            #expect(result.status == .success)
            #expect(result.output.contains("arg:hello"))
            #expect(result.output.contains("env:on"))
            #expect(result.output.contains(customCwd.path))
        }
    }

    @Test("ScriptRunner default workingDirectory is script parent and independent from shell cwd")
    func testScriptRunnerDefaultWorkingDirectory() async throws {
        try await withTestWorkspace(prefix: "flow-m0-script-cwd") { workspace in
            let scriptPath = try workspace.makeScript(
                name: "pwd.sh",
                content: "#!/bin/sh\npwd\n"
            )
            let script = Script(title: "Pwd", path: scriptPath, interpreter: .sh)
            let scriptDir = URL(fileURLWithPath: scriptPath).deletingLastPathComponent().path

            let otherCwd = workspace.rootURL.appendingPathComponent("other-cwd")
            try FileManager.default.createDirectory(at: otherCwd, withIntermediateDirectories: true)
            let previous = FileManager.default.currentDirectoryPath
            defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
            _ = FileManager.default.changeCurrentDirectoryPath(otherCwd.path)

            let runner = ScriptRunner()
            let result = try await runner.run(script, options: .init(args: [], env: [:], timeoutSec: 30))

            #expect(result.status == .success)
            #expect(result.output.contains(scriptDir))
            #expect(result.output.contains(otherCwd.path) == false)
        }
    }

    @Test("ScriptRunner timeout terminates long-running script")
    func testScriptRunnerTimeout() async throws {
        try await withTestWorkspace(prefix: "flow-m0-script-timeout") { workspace in
            let scriptPath = try workspace.makeScript(
                name: "sleep.sh",
                content: "#!/bin/sh\nsleep 3\necho done\n"
            )
            let script = Script(title: "Sleep", path: scriptPath, interpreter: .sh)
            let runner = ScriptRunner()
            let started = Date()
            let result = try await runner.run(script, options: .init(timeoutSec: 1))

            #expect(result.status == .failure)
            #expect(result.output.contains("done") == false)
            #expect(result.finishedAt?.timeIntervalSince(started) ?? 99 < 2.5)
            #expect(result.errorOutput.contains("timed out"))
        }
    }
}
