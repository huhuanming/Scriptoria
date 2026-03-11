import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow Engine", .serialized)
struct FlowEngineTests {
    @Test("TC-E01 precheck pass ends success without agent")
    func testGatePassDirectSuccess() async throws {
        try await withTestWorkspace(prefix: "flow-engine-pass") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {"states":{"precheck":[{"decision":"pass"}]}}
            """)

            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            let result = try await FlowEngine().run(ir: ir, mode: .dryRun(fixture), options: .init())

            #expect(result.status == .success)
            #expect(result.counters.isEmpty)
            #expect(result.endedAtStateID == "done")
        }
    }

    @Test("TC-E02 one agent round then success")
    func testOneRoundSuccess() async throws {
        try await withTestWorkspace(prefix: "flow-engine-one-round") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: fix
                  wait: pre_wait
                  fail: done_fail
              - id: pre_wait
                type: wait
                seconds: 0
                next: precheck
              - id: fix
                type: agent
                task: fix
                counter: fix_round
                max_rounds: 20
                export:
                  pr_url: "$.current.final.pr_url"
                next: postcheck
              - id: postcheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: fix
                  wait: pre_wait
                  fail: done_fail
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {
              "states": {
                "precheck": [{"decision": "needs_agent"}],
                "fix": [{"status": "completed", "final": {"pr_url": "https://example/pr/1"}}],
                "postcheck": [{"decision": "pass"}]
              }
            }
            """)

            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            let result = try await FlowEngine().run(ir: ir, mode: .dryRun(fixture), options: .init())
            #expect(result.status == .success)
            #expect(result.counters["fix_round"] == 1)
            #expect(result.context["pr_url"]?.stringValue == "https://example/pr/1")
        }
    }

    @Test("TC-E30 rounds exceeded returns flow.agent.rounds_exceeded")
    func testAgentRoundsExceeded() async throws {
        try await withTestWorkspace(prefix: "flow-engine-rounds") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: precheck
            defaults:
              max_agent_rounds: 2
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: fix
                  wait: pre_wait
                  fail: done_fail
              - id: pre_wait
                type: wait
                seconds: 0
                next: precheck
              - id: fix
                type: agent
                task: fix
                counter: fix_round
                max_rounds: 20
                next: precheck
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {
              "states": {
                "precheck": [
                  {"decision":"needs_agent"},
                  {"decision":"needs_agent"},
                  {"decision":"needs_agent"}
                ],
                "fix": [
                  {"status":"completed","final":{}},
                  {"status":"completed","final":{}}
                ]
              }
            }
            """)

            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            await requireFlowError("flow.agent.rounds_exceeded") {
                _ = try await FlowEngine().run(ir: ir, mode: .dryRun(fixture), options: .init())
            }
        }
    }

    @Test("TC-E27 wait cycles exceeded")
    func testWaitCyclesExceeded() async throws {
        try await withTestWorkspace(prefix: "flow-engine-wait-limit") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: precheck
            defaults:
              max_wait_cycles: 1
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: fix
                  wait: hold
                  fail: done_fail
              - id: hold
                type: wait
                seconds: 0
                next: precheck
              - id: fix
                type: agent
                task: fix
                next: done
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {"states":{"precheck":[{"decision":"wait"},{"decision":"wait"}]}}
            """)

            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            await requireFlowError("flow.wait.cycles_exceeded") {
                _ = try await FlowEngine().run(ir: ir, mode: .dryRun(fixture), options: .init())
            }
        }
    }

    @Test("TC-E28 max total steps exceeded")
    func testTotalStepsExceeded() async throws {
        try await withTestWorkspace(prefix: "flow-engine-steps-limit") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: precheck
            defaults:
              max_total_steps: 3
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: fix
                  wait: hold
                  fail: done_fail
              - id: hold
                type: wait
                seconds: 0
                next: precheck
              - id: fix
                type: agent
                task: fix
                next: done
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {"states":{"precheck":[{"decision":"wait"},{"decision":"wait"}]}}
            """)

            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            await requireFlowError("flow.steps.exceeded") {
                _ = try await FlowEngine().run(ir: ir, mode: .dryRun(fixture), options: .init())
            }
        }
    }

    @Test("TC-E31 end failure maps to flow.business_failed")
    func testBusinessFailure() async throws {
        try await withTestWorkspace(prefix: "flow-engine-business-fail") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {"states":{"precheck":[{"decision":"fail"}]}}
            """)

            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            await requireFlowError("flow.business_failed") {
                _ = try await FlowEngine().run(ir: ir, mode: .dryRun(fixture), options: .init())
            }
        }
    }

    @Test("TC-E43 wait.seconds larger than effective timeout fails immediately")
    func testWaitSecondsGreaterThanTimeout() async throws {
        try await withTestWorkspace(prefix: "flow-engine-wait-timeout") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: hold
            defaults:
              step_timeout_sec: 1
            states:
              - id: hold
                type: wait
                seconds: 3
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)

            await requireFlowError("flow.step.timeout") {
                _ = try await FlowEngine().run(ir: ir, mode: .live, options: .init())
            }
        }
    }

    @Test("TC-E46 script export parse failure")
    func testScriptExportParseFailure() async throws {
        try await withTestWorkspace(prefix: "flow-engine-script-export") { workspace in
            _ = try workspace.makeScript(name: "collect.sh", content: "#!/bin/sh\necho not-json\n")
            let flow = """
            version: flow/v1
            start: collect
            states:
              - id: collect
                type: script
                run: ./scripts/collect.sh
                export:
                  value: "$.current.final.value"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)

            await requireFlowError("flow.script.output_parse_error") {
                _ = try await FlowEngine().run(ir: ir, mode: .live, options: .init())
            }
        }
    }

    @Test("TC-E41 agent export null should be accepted")
    func testAgentExportNullValue() async throws {
        try await withTestWorkspace(prefix: "flow-engine-agent-null") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: fix
                  wait: hold
                  fail: done_fail
              - id: hold
                type: wait
                seconds: 0
                next: precheck
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
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: """
            {
              "states": {
                "precheck": [{"decision":"needs_agent"}],
                "fix": [{"status":"completed","final":{"pr_url":null}}]
              }
            }
            """)

            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            let result = try await FlowEngine().run(ir: ir, mode: .dryRun(fixture), options: .init())
            #expect(result.status == .success)
            #expect(result.context["pr_url"] == .null)
        }
    }
}

extension FlowEngineTests {
    @Test("TC-E39/TC-E40 agent timeout returns flow.step.timeout")
    func testAgentTimeout() async throws {
        try await withTestWorkspace(prefix: "flow-engine-agent-timeout") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "wait_for_command"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                defaults:
                  step_timeout_sec: 1
                states:
                  - id: fix
                    type: agent
                    task: fix-timeout
                    timeout_sec: 1
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let ir = try FlowCompiler.compileFile(atPath: flowPath)

                await requireFlowError("flow.step.timeout") {
                    _ = try await FlowEngine().run(ir: ir, mode: .live, options: .init(noSteer: true))
                }
            }
        }
    }
}
