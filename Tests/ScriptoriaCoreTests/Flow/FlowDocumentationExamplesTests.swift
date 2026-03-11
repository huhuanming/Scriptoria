import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow Documentation Examples", .serialized)
struct FlowDocumentationExamplesTests {
    @Test("documentation example flows should compile with default checks")
    func testExamplesCompile() throws {
        let root = repositoryRoot()
        let exampleFlows = [
            root.appendingPathComponent("docs/examples/flow-v1/local-gate-script/flow.yaml").path,
            root.appendingPathComponent("docs/examples/flow-v1/pr-loop/flow.yaml").path
        ]

        for flowPath in exampleFlows {
            _ = try FlowCompiler.compileFile(atPath: flowPath)
        }
    }

    @Test("documentation PR loop fixture should dry-run to success")
    func testPRLoopDryRunFixture() async throws {
        let root = repositoryRoot()
        let flowPath = root.appendingPathComponent("docs/examples/flow-v1/pr-loop/flow.yaml").path
        let fixturePath = root.appendingPathComponent("docs/examples/flow-v1/pr-loop/fixture.success.json").path

        let ir = try FlowCompiler.compileFile(atPath: flowPath)
        let fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
        let result = try await FlowEngine().run(ir: ir, mode: .dryRun(fixture))

        #expect(result.status == .success)
        #expect(result.endedAtStateID == "done")
        #expect(result.counters["fix_round"] == 2)
        #expect(result.context["pr_url"]?.stringValue == "https://github.com/org/repo/pull/123")
    }

    @Test("documentation local gate-script flow should run live without agent")
    func testLocalGateScriptLiveRun() async throws {
        let root = repositoryRoot()
        let flowPath = root.appendingPathComponent("docs/examples/flow-v1/local-gate-script/flow.yaml").path

        let ir = try FlowCompiler.compileFile(atPath: flowPath)
        let result = try await FlowEngine().run(ir: ir, mode: .live)

        #expect(result.status == .success)
        #expect(result.endedAtStateID == "done")
        #expect(result.context["summary"]?.stringValue == "local gate-script sample completed")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Flow
            .deletingLastPathComponent() // ScriptoriaCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }
}
