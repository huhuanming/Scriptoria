import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow Engine Coverage", .serialized)
struct FlowEngineCoverageTests {
    @Test("TC-E03 needs_agent loop should succeed at round N(<20)")
    func testNeedsAgentMultiRoundSuccess() async throws {
        try await withTestWorkspace(prefix: "flow-engine-round-n-success") { workspace in
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
              - id: fix
                type: agent
                task: fix
                counter: fix_round
                max_rounds: 20
                next: postcheck
              - id: postcheck
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
                next: postcheck
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
                "fix": [
                  {"status":"completed","final":{}},
                  {"status":"completed","final":{}},
                  {"status":"completed","final":{}}
                ],
                "postcheck": [
                  {"decision":"needs_agent"},
                  {"decision":"needs_agent"},
                  {"decision":"pass"}
                ]
              }
            }
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: fixture)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let dryFixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            let result = try await FlowEngine().run(ir: ir, mode: .dryRun(dryFixture))
            #expect(result.status == .success)
            #expect(result.counters["fix_round"] == 3)
        }
    }

    @Test("TC-E04 needs_agent loop should fail at round 21 with default cap 20")
    func testNeedsAgentRound21Fails() async throws {
        try await withTestWorkspace(prefix: "flow-engine-round-21-fail") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: precheck
            defaults:
              max_agent_rounds: 20
            states:
              - id: precheck
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
                max_rounds: 20
                next: postcheck
              - id: postcheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: fix
                  wait: done_fail
                  fail: done_fail
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """

            let needsAgentDecisions = Array(repeating: "{\"decision\":\"needs_agent\"}", count: 20).joined(separator: ",")
            let fixEntries = Array(repeating: "{\"status\":\"completed\",\"final\":{}}", count: 20).joined(separator: ",")
            let fixture = """
            {
              "states": {
                "precheck": [{"decision":"needs_agent"}],
                "postcheck": [\(needsAgentDecisions)],
                "fix": [\(fixEntries)]
              }
            }
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: fixture)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let dryFixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            await requireFlowError("flow.agent.rounds_exceeded") {
                _ = try await FlowEngine().run(ir: ir, mode: .dryRun(dryFixture))
            }
        }
    }

    @Test("TC-E05 postcheck wait should enter wait state then recheck")
    func testPostcheckWaitThenRecheck() async throws {
        try await withTestWorkspace(prefix: "flow-engine-postcheck-wait") { workspace in
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
                  wait: done_fail
                  fail: done_fail
              - id: fix
                type: agent
                task: fix
                counter: fix_round
                next: postcheck
              - id: postcheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: done_fail
                  wait: hold
                  fail: done_fail
              - id: hold
                type: wait
                seconds: 0
                next: postcheck
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
                "fix": [{"status":"completed","final":{}}],
                "postcheck": [{"decision":"wait"}, {"decision":"pass"}]
              }
            }
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: fixture)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let dryFixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            let result = try await FlowEngine().run(ir: ir, mode: .dryRun(dryFixture))
            #expect(result.status == .success)
            #expect(result.counters["fix_round"] == 1)
        }
    }

    @Test("TC-E07/TC-E19 max_wait_cycles should be global cumulative across wait states")
    func testGlobalWaitCyclesAcrossStates() async throws {
        try await withTestWorkspace(prefix: "flow-engine-global-wait-cycles") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: g1
            defaults:
              max_wait_cycles: 2
            states:
              - id: g1
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: w1
                  fail: done
              - id: w1
                type: wait
                seconds: 0
                next: g2
              - id: g2
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: w2
                  fail: done
              - id: w2
                type: wait
                seconds: 0
                next: g1
              - id: done
                type: end
                status: success
            """
            let fixture = """
            {
              "states": {
                "g1": [{"decision":"wait"}, {"decision":"wait"}],
                "g2": [{"decision":"wait"}]
              }
            }
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: fixture)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let dryFixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            await requireFlowError("flow.wait.cycles_exceeded") {
                _ = try await FlowEngine().run(ir: ir, mode: .dryRun(dryFixture))
            }
        }
    }

    @Test("TC-E08/TC-E22 agent failed should hard-fail and not map to business failure")
    func testAgentFailureIsHardFailure() async throws {
        try await withTestWorkspace(prefix: "flow-engine-agent-hard-fail") { workspace in
            let flow = """
            version: flow/v1
            start: fix
            states:
              - id: fix
                type: agent
                task: fail
                next: done_fail
              - id: done_fail
                type: end
                status: failure
            """
            let fixture = """
            {
              "states": {
                "fix": [{"status":"failed","final":{}}]
              }
            }
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: fixture)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let dryFixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            await requireFlowError("flow.agent.failed") {
                _ = try await FlowEngine().run(ir: ir, mode: .dryRun(dryFixture))
            }
        }
    }

    @Test("TC-E09 user interrupt command should return flow.agent.interrupted")
    func testUserInterruptByCommand() async throws {
        try await withTestWorkspace(prefix: "flow-engine-user-interrupt") { workspace in
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
                let ir = try FlowCompiler.compileFile(atPath: flowPath)
                await requireFlowError("flow.agent.interrupted") {
                    _ = try await FlowEngine().run(
                        ir: ir,
                        mode: .live,
                        options: .init(noSteer: true, commands: ["/interrupt"])
                    )
                }
            }
        }
    }

    @Test("TC-E12/TC-E13/TC-E14 seconds_from resolve edge cases")
    func testWaitSecondsFromEdgeCases() async throws {
        try await withTestWorkspace(prefix: "flow-engine-wait-seconds-from-edge") { workspace in
            let missingValueFlow = """
            version: flow/v1
            start: hold
            states:
              - id: hold
                type: wait
                seconds_from: "$.context.missing"
                next: done
              - id: done
                type: end
                status: success
            """
            let missingPath = try writeFlowFile(workspace: workspace, name: "missing.yaml", content: missingValueFlow)
            let missingIR = try FlowCompiler.compileFile(atPath: missingPath)
            await requireFlowError("flow.wait.seconds_resolve_error") {
                _ = try await FlowEngine().run(ir: missingIR, mode: .live)
            }

            let zeroFlow = """
            version: flow/v1
            start: hold
            context:
              sec: 0
            states:
              - id: hold
                type: wait
                seconds_from: "$.context.sec"
                next: done
              - id: done
                type: end
                status: success
            """
            let zeroPath = try writeFlowFile(workspace: workspace, name: "zero.yaml", content: zeroFlow)
            let zeroIR = try FlowCompiler.compileFile(atPath: zeroPath)
            let zeroResult = try await FlowEngine().run(ir: zeroIR, mode: .live)
            #expect(zeroResult.status == .success)

            let negativeFlow = """
            version: flow/v1
            start: hold
            context:
              sec: -1
            states:
              - id: hold
                type: wait
                seconds_from: "$.context.sec"
                next: done
              - id: done
                type: end
                status: success
            """
            let negativePath = try writeFlowFile(workspace: workspace, name: "negative.yaml", content: negativeFlow)
            let negativeIR = try FlowCompiler.compileFile(atPath: negativePath)
            await requireFlowError("flow.wait.seconds_resolve_error") {
                _ = try await FlowEngine().run(ir: negativeIR, mode: .live)
            }
        }
    }

    @Test("TC-E16 script success path should complete")
    func testScriptSuccessPath() async throws {
        try await withTestWorkspace(prefix: "flow-engine-script-success") { workspace in
            _ = try workspace.makeScript(name: "ok.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/ok.sh
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let result = try await FlowEngine().run(ir: ir, mode: .live)
            #expect(result.status == .success)
            #expect(result.endedAtStateID == "done")
        }
    }

    @Test("TC-E18 gate-script loop without agent/wait should be terminated by max_total_steps")
    func testGateScriptLoopStopsByStepLimit() async throws {
        try await withTestWorkspace(prefix: "flow-engine-gate-script-loop-limit") { workspace in
            _ = try workspace.makeScript(name: "gate-pass.sh", content: "#!/bin/sh\necho '{\"decision\":\"pass\"}'\n")
            _ = try workspace.makeScript(name: "noop.sh", content: "#!/bin/sh\necho noop\n")
            let flow = """
            version: flow/v1
            start: gate
            defaults:
              max_total_steps: 3
            states:
              - id: gate
                type: gate
                run: ./scripts/gate-pass.sh
                on:
                  pass: run
                  needs_agent: run
                  wait: run
                  fail: run
              - id: run
                type: script
                run: ./scripts/noop.sh
                next: gate
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            await requireFlowError("flow.steps.exceeded") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E26 gate decision fail should follow on.fail branch")
    func testGateFailDecisionUsesBusinessTransition() async throws {
        try await withTestWorkspace(prefix: "flow-engine-gate-fail-branch") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let flow = """
            version: flow/v1
            start: gate
            states:
              - id: gate
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done_fail
                  needs_agent: done_fail
                  wait: done_fail
                  fail: done
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
                "gate": [{"decision":"fail"}]
              }
            }
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let fixturePath = try writeFixtureFile(workspace: workspace, json: fixture)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let dryFixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            let result = try await FlowEngine().run(ir: ir, mode: .dryRun(dryFixture))
            #expect(result.status == .success)
            #expect(result.endedAtStateID == "done")
        }
    }

    @Test("TC-E32/TC-E33 inclusive limits should allow exactly-at-limit execution")
    func testInclusiveLimitBoundaries() async throws {
        try await withTestWorkspace(prefix: "flow-engine-inclusive-limits") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho should-not-run\n")
            let waitFlow = """
            version: flow/v1
            start: gate
            defaults:
              max_wait_cycles: 2
            states:
              - id: gate
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: hold
                  fail: done
              - id: hold
                type: wait
                seconds: 0
                next: gate
              - id: done
                type: end
                status: success
            """
            let waitFixture = """
            {
              "states": {
                "gate": [{"decision":"wait"}, {"decision":"wait"}, {"decision":"pass"}]
              }
            }
            """
            let waitFlowPath = try writeFlowFile(workspace: workspace, name: "wait-limit.yaml", content: waitFlow)
            let waitFixturePath = try writeFixtureFile(workspace: workspace, name: "wait-limit.json", json: waitFixture)
            let waitIR = try FlowCompiler.compileFile(atPath: waitFlowPath)
            let waitDryFixture = try FlowDryRunFixture.load(fromPath: waitFixturePath)
            let waitResult = try await FlowEngine().run(ir: waitIR, mode: .dryRun(waitDryFixture))
            #expect(waitResult.status == .success)

            _ = try workspace.makeScript(name: "noop.sh", content: "#!/bin/sh\necho ok\n")
            let stepFlow = """
            version: flow/v1
            start: a
            defaults:
              max_total_steps: 3
            states:
              - id: a
                type: script
                run: ./scripts/noop.sh
                next: b
              - id: b
                type: script
                run: ./scripts/noop.sh
                next: done
              - id: done
                type: end
                status: success
            """
            let stepFlowPath = try writeFlowFile(workspace: workspace, name: "step-limit.yaml", content: stepFlow)
            let stepIR = try FlowCompiler.compileFile(atPath: stepFlowPath)
            let stepResult = try await FlowEngine().run(ir: stepIR, mode: .live)
            #expect(stepResult.status == .success)
            #expect(stepResult.steps == 3)
        }
    }

    @Test("TC-P05 running command stream should be consumed during active agent turn")
    func testRunningCommandStreamConsumption() async throws {
        try await withTestWorkspace(prefix: "flow-engine-running-command-stream") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "wait_for_command_json"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                states:
                  - id: fix
                    type: agent
                    task: delayed-command
                    timeout_sec: 2
                    export:
                      received: "$.current.final.received"
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let ir = try FlowCompiler.compileFile(atPath: flowPath)

                let stream = AsyncStream<String> { continuation in
                    Task.detached {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        continuation.yield("delayed-live-command")
                        continuation.finish()
                    }
                }

                let result = try await FlowEngine().run(
                    ir: ir,
                    mode: .live,
                    options: .init(),
                    commandInput: stream
                )
                #expect(result.status == .success)
                #expect(result.context["received"]?.stringValue == "delayed-live-command")
            }
        }
    }
}
