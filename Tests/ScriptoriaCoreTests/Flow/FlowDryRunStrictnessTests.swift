import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow Dry Run Strictness", .serialized)
struct FlowDryRunStrictnessTests {
    @Test("TC-CLI10 dry-run fixture unknown state should fail")
    func testDryRunUnknownState() async throws {
        try await withTestWorkspace(prefix: "flow-dryrun-unknown-state") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {"states":{"ghost":[{"decision":"pass"}]}}
            """)

            let run = try runCLI(arguments: ["flow", "dry-run", flowPath, "--fixture", fixturePath])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("flow.dryrun.fixture_unknown_state"))
            #expect(run.stdout.contains("phase=runtime-dry-run"))
        }
    }

    @Test("TC-CLI11 dry-run executed state with unconsumed entries should fail")
    func testDryRunUnconsumedItems() async throws {
        try await withTestWorkspace(prefix: "flow-dryrun-unconsumed") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {"states":{"precheck":[{"decision":"pass"},{"decision":"pass"}]}}
            """)

            let run = try runCLI(arguments: ["flow", "dry-run", flowPath, "--fixture", fixturePath])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("flow.dryrun.fixture_unconsumed_items"))
        }
    }

    @Test("TC-CLI12 dry-run unexecuted state data should warn only")
    func testDryRunUnusedStateDataWarning() async throws {
        try await withTestWorkspace(prefix: "flow-dryrun-unused") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {
              "states": {
                "precheck": [{"decision":"pass"}],
                "fix": [{"status":"completed","final":{}}]
              }
            }
            """)

            let run = try runCLI(arguments: ["flow", "dry-run", flowPath, "--fixture", fixturePath])
            #expect(run.exitCode == 0)
            #expect(run.stdout.contains("flow.dryrun.fixture_unused_state_data"))
        }
    }
}
