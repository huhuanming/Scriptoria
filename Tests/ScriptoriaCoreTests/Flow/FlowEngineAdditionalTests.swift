import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow Engine Additional", .serialized)
struct FlowEngineAdditionalTests {
    @Test("TC-E17 script process non-zero should fail")
    func testScriptProcessExitNonZero() async throws {
        try await withTestWorkspace(prefix: "flow-engine-script-exit") { workspace in
            _ = try workspace.makeScript(name: "fail.sh", content: "#!/bin/sh\nexit 3\n")
            let flow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/fail.sh
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            await requireFlowError("flow.script.process_exit_nonzero") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E47/TC-GP09 gate process non-zero should fail")
    func testGateProcessExitNonZero() async throws {
        try await withTestWorkspace(prefix: "flow-engine-gate-exit") { workspace in
            _ = try workspace.makeScript(name: "gate-fail.sh", content: "#!/bin/sh\nexit 7\n")
            let flow = """
            version: flow/v1
            start: gate
            states:
              - id: gate
                type: gate
                run: ./scripts/gate-fail.sh
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
            await requireFlowError("flow.gate.process_exit_nonzero") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E37/TC-GP11 fail_on_parse_error=false should jump via on.parse_error")
    func testGateParseErrorBranch() async throws {
        try await withTestWorkspace(prefix: "flow-engine-parse-error-branch") { workspace in
            _ = try workspace.makeScript(name: "gate.sh", content: "#!/bin/sh\necho not-json\n")
            let flow = """
            version: flow/v1
            start: gate
            defaults:
              fail_on_parse_error: false
            states:
              - id: gate
                type: gate
                run: ./scripts/gate.sh
                on:
                  pass: done_fail
                  needs_agent: done_fail
                  wait: done_fail
                  fail: done_fail
                  parse_error: done
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let result = try await FlowEngine().run(ir: ir, mode: .live)
            #expect(result.status == .success)
            #expect(result.endedAtStateID == "done")
        }
    }

    @Test("TC-E10 expression resolve error")
    func testExpressionResolveError() async throws {
        try await withTestWorkspace(prefix: "flow-engine-expr-resolve") { workspace in
            _ = try workspace.makeScript(name: "echo.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/echo.sh
                args:
                  - "$.context.missing_key"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            await requireFlowError("flow.expr.resolve_error") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E34 expression type error for args/env")
    func testExpressionTypeError() async throws {
        try await withTestWorkspace(prefix: "flow-engine-expr-type") { workspace in
            _ = try workspace.makeScript(name: "echo.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: run
            context:
              obj:
                a: 1
            states:
              - id: run
                type: script
                run: ./scripts/echo.sh
                args:
                  - "$.context.obj"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            await requireFlowError("flow.expr.type_error") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E35 wait.seconds_from non-integer should fail")
    func testWaitSecondsFromInvalid() async throws {
        try await withTestWorkspace(prefix: "flow-engine-wait-seconds-from") { workspace in
            let flow = """
            version: flow/v1
            start: hold
            context:
              retry: abc
            states:
              - id: hold
                type: wait
                seconds_from: "$.context.retry"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            await requireFlowError("flow.wait.seconds_resolve_error") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E45 wait.seconds == timeout should pass")
    func testWaitSecondsEqualsTimeout() async throws {
        try await withTestWorkspace(prefix: "flow-engine-wait-eq-timeout") { workspace in
            let flow = """
            version: flow/v1
            start: hold
            states:
              - id: hold
                type: wait
                seconds: 1
                timeout_sec: 1
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let result = try await FlowEngine().run(ir: ir, mode: .live)
            #expect(result.status == .success)
        }
    }

    @Test("TC-E36 args/env number-bool expression result should stringify")
    func testArgsEnvExpressionStringify() async throws {
        try await withTestWorkspace(prefix: "flow-engine-args-env-str") { workspace in
            _ = try workspace.makeScript(
                name: "echo-json.sh",
                content: "#!/bin/sh\nprintf '{\"value\":\"%s|%s\"}\n' \"$1\" \"$FLAG\"\n"
            )
            let flow = """
            version: flow/v1
            start: run
            context:
              num: 42
              flag: true
            states:
              - id: run
                type: script
                run: ./scripts/echo-json.sh
                args:
                  - "$.context.num"
                env:
                  FLAG: "$.context.flag"
                export:
                  out: "$.current.final.value"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let result = try await FlowEngine().run(ir: ir, mode: .live)
            #expect(result.context["out"]?.stringValue == "42|true")
        }
    }

    @Test("TC-E42 script.export null should be accepted")
    func testScriptExportNull() async throws {
        try await withTestWorkspace(prefix: "flow-engine-script-null") { workspace in
            _ = try workspace.makeScript(name: "null-json.sh", content: "#!/bin/sh\necho '{\"value\":null}'\n")
            let flow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/null-json.sh
                export:
                  output: "$.current.final.value"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let result = try await FlowEngine().run(ir: ir, mode: .live)
            #expect(result.status == .success)
            #expect(result.context["output"] == .null)
        }
    }

    @Test("TC-E38 runtime path missing after preflight")
    func testRuntimePathMissingAfterPreflight() async throws {
        try await withTestWorkspace(prefix: "flow-engine-runtime-path-missing") { workspace in
            let victimPath = try workspace.makeScript(name: "victim.sh", content: "#!/bin/sh\necho hi\n")
            _ = try workspace.makeScript(name: "remover.sh", content: "#!/bin/sh\nrm -f \"$TARGET\"\n")

            let flow = """
            version: flow/v1
            start: remove
            states:
              - id: remove
                type: script
                run: ./scripts/remover.sh
                env:
                  TARGET: "\(victimPath)"
                next: victim
              - id: victim
                type: script
                run: ./scripts/victim.sh
                next: done
              - id: done
                type: end
                status: success
            """

            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            await requireFlowError("flow.path.not_found") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E20/TC-E21 default counters isolated, shared counters merged")
    func testCounterIsolationAndSharing() async throws {
        try await withTestWorkspace(prefix: "flow-engine-counters") { workspace in
            let isolated = """
            version: flow/v1
            start: a
            states:
              - id: a
                type: agent
                task: task-a
                next: b
              - id: b
                type: agent
                task: task-b
                next: done
              - id: done
                type: end
                status: success
            """
            let isolatedFlowPath = try writeFlowFile(workspace: workspace, name: "isolated.yaml", content: isolated)
            let isolatedFixturePath = try writeFixtureFile(workspace: workspace, name: "isolated.json", json: """
            {"states":{"a":[{"status":"completed","final":{}}],"b":[{"status":"completed","final":{}}]}}
            """)

            let isolatedIR = try FlowCompiler.compileFile(atPath: isolatedFlowPath)
            let isolatedFixture = try FlowDryRunFixture.load(fromPath: isolatedFixturePath)
            let isolatedResult = try await FlowEngine().run(ir: isolatedIR, mode: .dryRun(isolatedFixture))
            #expect(isolatedResult.counters["agent_round.a"] == 1)
            #expect(isolatedResult.counters["agent_round.b"] == 1)

            let shared = """
            version: flow/v1
            start: a
            states:
              - id: a
                type: agent
                task: task-a
                counter: shared_round
                next: b
              - id: b
                type: agent
                task: task-b
                counter: shared_round
                next: done
              - id: done
                type: end
                status: success
            """
            let sharedFlowPath = try writeFlowFile(workspace: workspace, name: "shared.yaml", content: shared)
            let sharedFixturePath = try writeFixtureFile(workspace: workspace, name: "shared.json", json: """
            {"states":{"a":[{"status":"completed","final":{}}],"b":[{"status":"completed","final":{}}]}}
            """)

            let sharedIR = try FlowCompiler.compileFile(atPath: sharedFlowPath)
            let sharedFixture = try FlowDryRunFixture.load(fromPath: sharedFixturePath)
            let sharedResult = try await FlowEngine().run(ir: sharedIR, mode: .dryRun(sharedFixture))
            #expect(sharedResult.counters["shared_round"] == 2)
        }
    }

    @Test("TC-E06 wait should not increase agent rounds")
    func testWaitDoesNotIncreaseAgentCounter() async throws {
        try await withTestWorkspace(prefix: "flow-engine-wait-no-round") { workspace in
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
                next: post
              - id: post
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
                next: post
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let fixturePath = try writeFixtureFile(workspace: workspace, name: "wait-no-round.json", json: """
            {
              "states": {
                "precheck": [{"decision": "needs_agent"}],
                "fix": [{"status": "completed", "final": {}}],
                "post": [{"decision": "wait"}, {"decision": "pass"}]
              }
            }
            """)
            let flowPath = try writeFlowFile(workspace: workspace, name: "wait-no-round.yaml", content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
            let result = try await FlowEngine().run(ir: ir, mode: .dryRun(fixture))
            #expect(result.status == .success)
            #expect(result.counters["fix_round"] == 1)
        }
    }

    @Test("TC-E15/TC-E29 gate timeout should map to flow.step.timeout")
    func testGateTimeoutMapsToStepTimeout() async throws {
        try await withTestWorkspace(prefix: "flow-engine-gate-timeout") { workspace in
            _ = try workspace.makeScript(
                name: "gate-slow.sh",
                content: "#!/bin/sh\nsleep 2\necho '{\"decision\":\"pass\"}'\n"
            )
            let flow = """
            version: flow/v1
            start: gate
            states:
              - id: gate
                type: gate
                run: ./scripts/gate-slow.sh
                timeout_sec: 1
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
            await requireFlowError("flow.step.timeout") {
                _ = try await FlowEngine().run(ir: ir, mode: .live)
            }
        }
    }

    @Test("TC-E15/TC-E29 script timeout should map to flow.step.timeout")
    func testScriptTimeoutMapsToStepTimeout() async throws {
        try await withTestWorkspace(prefix: "flow-engine-script-timeout") { workspace in
            _ = try workspace.makeScript(name: "slow.sh", content: "#!/bin/sh\nsleep 2\n")
            let flow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/slow.sh
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
}
