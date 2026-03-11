import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow Provider E2E", .serialized)
struct FlowProviderE2ETests {
    @Test("TC-P01 flow run + codex provider should run end-to-end")
    func testCodexProviderE2E() async throws {
        try await withTestWorkspace(prefix: "flow-provider-codex") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "complete"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                states:
                  - id: fix
                    type: agent
                    task: codex-e2e
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
                #expect(run.exitCode == 0)
            }
        }
    }

    @Test("TC-P02 flow run + claude adapter executable should run end-to-end")
    func testClaudeAdapterE2E() async throws {
        try await withTestWorkspace(prefix: "flow-provider-claude") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            let adapterURL = workspace.rootURL.appendingPathComponent("agents/claude-adapter")
            try FileManager.default.createDirectory(
                at: adapterURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(atPath: codexPath, toPath: adapterURL.path)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: adapterURL.path)

            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": adapterURL.path,
                "SCRIPTORIA_FAKE_CODEX_MODE": "complete"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                states:
                  - id: fix
                    type: agent
                    task: claude-e2e
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
                #expect(run.exitCode == 0)
            }
        }
    }

    @Test("TC-P03 flow run + kimi adapter executable should run end-to-end")
    func testKimiAdapterE2E() async throws {
        try await withTestWorkspace(prefix: "flow-provider-kimi") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            let adapterURL = workspace.rootURL.appendingPathComponent("agents/kimi-adapter")
            try FileManager.default.createDirectory(
                at: adapterURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(atPath: codexPath, toPath: adapterURL.path)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: adapterURL.path)

            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": adapterURL.path,
                "SCRIPTORIA_FAKE_CODEX_MODE": "complete"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                states:
                  - id: fix
                    type: agent
                    task: kimi-e2e
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
                #expect(run.exitCode == 0)
            }
        }
    }

    @Test("TC-P04 flow run should show streaming output during agent execution")
    func testStreamingOutputVisible() async throws {
        try await withTestWorkspace(prefix: "flow-provider-streaming") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "complete"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                states:
                  - id: fix
                    type: agent
                    task: stream
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
                #expect(run.exitCode == 0)
                #expect(run.stdout.contains("agent delta"))
                #expect(run.stdout.contains("command delta"))
            }
        }
    }

    @Test("TC-P06 flow run --command /interrupt should return flow.agent.interrupted")
    func testInterruptCommandProviderPath() async throws {
        try await withTestWorkspace(prefix: "flow-provider-interrupt") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "wait_for_command"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                states:
                  - id: fix
                    type: agent
                    task: interrupt
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(
                    arguments: ["flow", "run", flowPath, "--command", "/interrupt", "--no-steer"]
                )
                #expect(run.exitCode != 0)
                #expect(run.stdout.contains("flow.agent.interrupted"))
            }
        }
    }
}
