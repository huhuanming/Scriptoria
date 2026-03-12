import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow Error Boundaries", .serialized)
struct FlowErrorBoundaryTests {
    @Test("TC-E24 agent export field missing")
    func testAgentExportFieldMissing() async throws {
        try await withTestWorkspace(prefix: "flow-error-agent-export-missing") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done_fail
                  needs_agent: fix
                  wait: done_fail
                  fail: done_fail
              - id: fix
                type: agent
                task: fix
                export:
                  pr_url: "$.current.final.pr_url"
                next: done
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let fixture = """
            {
              "states": {
                "precheck": [{"decision":"needs_agent"}],
                "fix": [{"status":"completed","final":{}}]
              }
            }
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: fixture)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let dryFixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            await requireFlowError("flow.agent.export_field_missing") {
                _ = try await FlowEngine().run(ir: ir, mode: .dryRun(dryFixture))
            }
        }
    }

    @Test("TC-E25 script export field missing")
    func testScriptExportFieldMissing() async throws {
        try await withTestWorkspace(prefix: "flow-error-script-export-missing") { workspace in
            _ = try workspace.makeScript(name: "obj.sh", content: "#!/bin/sh\necho '{\"x\":1}'\n")
            let flow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/obj.sh
                export:
                  value: "$.current.final.value"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            await requireFlowError("flow.script.export_field_missing") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E23 agent output parse error when export required")
    func testAgentOutputParseError() async throws {
        try await withTestWorkspace(prefix: "flow-error-agent-output-parse") { workspace in
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
                    task: parse
                    export:
                      value: "$.current.final.value"
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let ir = try FlowCompiler.compileFile(atPath: flowPath)
                await requireFlowError("flow.agent.output_parse_error") {
                    _ = try await FlowEngine().run(ir: ir, mode: .live)
                }
            }
        }
    }

    @Test("TC-GP10 parse error with fail_on_parse_error=true should fail")
    func testGateParseErrorFailFast() async throws {
        try await withTestWorkspace(prefix: "flow-error-gate-parse-fast") { workspace in
            _ = try workspace.makeScript(name: "gate.sh", content: "#!/bin/sh\necho not-json\n")
            let flow = """
            version: flow/v1
            start: gate
            defaults:
              fail_on_parse_error: true
            states:
              - id: gate
                type: gate
                run: ./scripts/gate.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: done
                  fail: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            await requireFlowError("flow.gate.parse_error") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E44 wait.seconds_from greater than timeout should fail with timeout")
    func testWaitSecondsFromGreaterThanTimeout() async throws {
        try await withTestWorkspace(prefix: "flow-error-wait-from-timeout") { workspace in
            let flow = """
            version: flow/v1
            start: hold
            context:
              wait_sec: 3
            states:
              - id: hold
                type: wait
                seconds_from: "$.context.wait_sec"
                timeout_sec: 1
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            await requireFlowError("flow.step.timeout") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E11 max rounds equals limit should still pass")
    func testAgentRoundsAtLimitPasses() async throws {
        try await withTestWorkspace(prefix: "flow-error-rounds-at-limit") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: gate
            defaults:
              max_agent_rounds: 2
            states:
              - id: gate
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: fix
                  wait: done_fail
                  fail: done_fail
              - id: fix
                type: agent
                task: fix
                counter: fix_round
                max_rounds: 2
                next: gate2
              - id: gate2
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: fix2
                  wait: done_fail
                  fail: done_fail
              - id: fix2
                type: agent
                task: fix
                counter: fix_round
                max_rounds: 2
                next: gate3
              - id: gate3
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: done_fail
                  wait: done_fail
                  fail: done_fail
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let fixture = """
            {
              "states": {
                "gate": [{"decision":"needs_agent"}],
                "fix": [{"status":"completed","final":{}}],
                "gate2": [{"decision":"needs_agent"}],
                "fix2": [{"status":"completed","final":{}}],
                "gate3": [{"decision":"pass"}]
              }
            }
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: fixture)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let dryFixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            let result = try await FlowEngine().run(ir: ir, mode: .dryRun(dryFixture))
            #expect(result.status == .success)
            #expect(result.counters["fix_round"] == 2)
        }
    }
}
