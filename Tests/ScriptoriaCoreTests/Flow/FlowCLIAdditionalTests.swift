import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow CLI Additional", .serialized)
struct FlowCLIAdditionalTests {
    @Test("TC-CLI04 flow run success path should return 0")
    func testFlowRunSuccessPath() async throws {
        try await withTestWorkspace(prefix: "flow-cli-run-success") { workspace in
            _ = try workspace.makeScript(name: "gate-pass.sh", content: "#!/bin/sh\necho '{\"decision\":\"pass\"}'\n")
            let flow = """
            version: flow/v1
            start: gate
            states:
              - id: gate
                type: gate
                run: ./scripts/gate-pass.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: done
                  fail: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, name: "run-success.yaml", content: flow)
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
            #expect(run.exitCode == 0)
            #expect(run.stdout.contains("phase=runtime"))
        }
    }

    @Test("TC-CLI05 flow run rounds exceeded should return non-zero")
    func testFlowRunRoundsExceededNonZero() async throws {
        try await withTestWorkspace(prefix: "flow-cli-run-rounds-exceeded") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "complete"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                defaults:
                  max_agent_rounds: 1
                states:
                  - id: fix
                    type: agent
                    task: loop
                    max_rounds: 20
                    next: fix
                """
                let flowPath = try writeFlowFile(workspace: workspace, name: "rounds-exceeded.yaml", content: flow)
                let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
                #expect(run.exitCode != 0)
                #expect(run.stdout.contains("flow.agent.rounds_exceeded"))
            }
        }
    }

    @Test("TC-CLI07 flow dry-run fixture should drive transitions correctly")
    func testFlowDryRunFixtureSuccess() async throws {
        try await withTestWorkspace(prefix: "flow-cli-dry-run-success") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let fixturePath = try writeFixtureFile(
                workspace: workspace,
                json: """
                {"states":{"precheck":[{"decision":"pass"}]}}
                """
            )
            let run = try runCLI(arguments: ["flow", "dry-run", flowPath, "--fixture", fixturePath])
            #expect(run.exitCode == 0)
            #expect(run.stdout.contains("phase=runtime"))
        }
    }

    @Test("TC-CLI18 --var value should be injected as string")
    func testVarInjectionAsString() async throws {
        try await withTestWorkspace(prefix: "flow-cli-var-string") { workspace in
            let outputPath = workspace.rootURL.appendingPathComponent("var-string.txt").path
            _ = try workspace.makeScript(name: "gate-pass.sh", content: "#!/bin/sh\necho '{\"decision\":\"pass\"}'\n")
            _ = try workspace.makeScript(name: "write.sh", content: "#!/bin/sh\necho \"$1\" > \"\(outputPath)\"\n")
            let flow = """
            version: flow/v1
            start: gate
            context:
              x: old
            states:
              - id: gate
                type: gate
                run: ./scripts/gate-pass.sh
                on:
                  pass: write
                  needs_agent: done
                  wait: done
                  fail: done
              - id: write
                type: script
                run: ./scripts/write.sh
                args:
                  - "$.context.x"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, name: "var-string.yaml", content: flow)
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--var", "x=1", "--no-steer"])
            #expect(run.exitCode == 0)
            let value = try String(contentsOfFile: outputPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(value == "1")
        }
    }

    @Test("TC-CLI06 --max-agent-rounds should tighten cap")
    func testMaxAgentRoundsCapTightens() async throws {
        try await withTestWorkspace(prefix: "flow-cli-cap-tighten") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "complete"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                defaults:
                  max_agent_rounds: 20
                  max_total_steps: 20
                states:
                  - id: fix
                    type: agent
                    task: loop
                    next: fix
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(arguments: [
                    "flow", "run", flowPath,
                    "--max-agent-rounds", "1",
                    "--no-steer"
                ])
                #expect(run.exitCode != 0)
                #expect(run.stdout.contains("flow.agent.rounds_exceeded"))
            }
        }
    }

    @Test("TC-CLI14 cap greater than config should warn and not relax")
    func testMaxAgentRoundsCapGreaterThanConfigWarns() async throws {
        try await withTestWorkspace(prefix: "flow-cli-cap-warning") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "complete"
            ]) {
                let flow = """
                version: flow/v1
                start: fix
                defaults:
                  max_agent_rounds: 1
                  max_total_steps: 10
                states:
                  - id: fix
                    type: agent
                    task: loop
                    max_rounds: 1
                    next: fix
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(arguments: [
                    "flow", "run", flowPath,
                    "--max-agent-rounds", "5",
                    "--no-steer"
                ])
                #expect(run.exitCode != 0)
                #expect(run.stdout.contains("flow.agent.rounds_exceeded"))
                #expect(run.stdout.contains("flow.cli.max_agent_rounds_cap_ignored"))
            }
        }
    }

    @Test("TC-CLI15 business failure should return flow.business_failed")
    func testBusinessFailureCode() async throws {
        try await withTestWorkspace(prefix: "flow-cli-business-fail") { workspace in
            _ = try workspace.makeScript(name: "gate.sh", content: "#!/bin/sh\necho '{\"decision\":\"fail\"}'\n")
            let flow = """
            version: flow/v1
            start: gate
            states:
              - id: gate
                type: gate
                run: ./scripts/gate.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: done
                  fail: done_fail
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("flow.business_failed"))
        }
    }

    @Test("TC-CLI16/TC-CLI17 steps and wait limits should surface correct error codes")
    func testStepAndWaitLimitCodes() async throws {
        try await withTestWorkspace(prefix: "flow-cli-limits") { workspace in
            _ = try workspace.makeScript(name: "gate.sh", content: "#!/bin/sh\necho '{\"decision\":\"wait\"}'\n")

            let stepsFlow = """
            version: flow/v1
            start: gate
            defaults:
              max_total_steps: 2
            states:
              - id: gate
                type: gate
                run: ./scripts/gate.sh
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
            let stepsPath = try writeFlowFile(workspace: workspace, name: "steps.yaml", content: stepsFlow)
            let stepsRun = try runCLI(arguments: ["flow", "run", stepsPath, "--no-steer"])
            #expect(stepsRun.exitCode != 0)
            #expect(stepsRun.stdout.contains("flow.steps.exceeded"))

            let waitFlow = """
            version: flow/v1
            start: gate
            defaults:
              max_wait_cycles: 1
            states:
              - id: gate
                type: gate
                run: ./scripts/gate.sh
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
            let waitPath = try writeFlowFile(workspace: workspace, name: "wait.yaml", content: waitFlow)
            let waitRun = try runCLI(arguments: ["flow", "run", waitPath, "--no-steer"])
            #expect(waitRun.exitCode != 0)
            #expect(waitRun.stdout.contains("flow.wait.cycles_exceeded"))
        }
    }

    @Test("TC-CLI22 runtime path missing should return flow.path.not_found")
    func testRuntimePathMissingCode() async throws {
        try await withTestWorkspace(prefix: "flow-cli-runtime-path-missing") { workspace in
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
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("flow.path.not_found"))
        }
    }

    @Test("TC-CLI26/TC-CLI27 script non-zero and agent failure codes")
    func testScriptAndAgentFailureCodes() async throws {
        try await withTestWorkspace(prefix: "flow-cli-script-agent-fail") { workspace in
            _ = try workspace.makeScript(name: "script-fail.sh", content: "#!/bin/sh\nexit 9\n")
            let scriptFlow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/script-fail.sh
                next: done
              - id: done
                type: end
                status: success
            """
            let scriptFlowPath = try writeFlowFile(workspace: workspace, name: "script-fail.yaml", content: scriptFlow)
            let scriptRun = try runCLI(arguments: ["flow", "run", scriptFlowPath, "--no-steer"])
            #expect(scriptRun.exitCode != 0)
            #expect(scriptRun.stdout.contains("flow.script.process_exit_nonzero"))

            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "exit_after_turn_start"
            ]) {
                let agentFlow = """
                version: flow/v1
                start: fix
                states:
                  - id: fix
                    type: agent
                    task: fail-agent
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let agentFlowPath = try writeFlowFile(workspace: workspace, name: "agent-fail.yaml", content: agentFlow)
                let agentRun = try runCLI(arguments: ["flow", "run", agentFlowPath, "--no-steer"])
                #expect(agentRun.exitCode != 0)
                #expect(agentRun.stdout.contains("flow.agent.failed"))
            }
        }
    }

    @Test("TC-CLI29/TC-CLI31 interrupt and command-unused behaviors")
    func testCommandInterruptAndUnusedWarning() async throws {
        try await withTestWorkspace(prefix: "flow-cli-command-behavior") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "wait_for_command"
            ]) {
                let interruptFlow = """
                version: flow/v1
                start: fix
                states:
                  - id: fix
                    type: agent
                    task: interrupt-me
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let interruptPath = try writeFlowFile(workspace: workspace, name: "interrupt.yaml", content: interruptFlow)
                let interruptRun = try runCLI(arguments: [
                    "flow", "run", interruptPath,
                    "--command", "/interrupt",
                    "--no-steer"
                ])
                #expect(interruptRun.exitCode != 0)
                #expect(interruptRun.stdout.contains("flow.agent.interrupted"))
            }

            _ = try workspace.makeScript(name: "gate-pass.sh", content: "#!/bin/sh\necho '{\"decision\":\"pass\"}'\n")
            let noAgentFlow = """
            version: flow/v1
            start: gate
            states:
              - id: gate
                type: gate
                run: ./scripts/gate-pass.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: done
                  fail: done
              - id: done
                type: end
                status: success
            """
            let noAgentPath = try writeFlowFile(workspace: workspace, name: "no-agent.yaml", content: noAgentFlow)
            let noAgentRun = try runCLI(arguments: [
                "flow", "run", noAgentPath,
                "--command", "refine this",
                "--no-steer"
            ])
            #expect(noAgentRun.exitCode == 0)
            #expect(noAgentRun.stdout.contains("flow.cli.command_unused"))
        }
    }

    @Test("TC-CLI36 all commands should be unused when flow never enters agent")
    func testAllCommandsUnusedWithoutAgentState() async throws {
        try await withTestWorkspace(prefix: "flow-cli-all-commands-unused") { workspace in
            _ = try workspace.makeScript(name: "gate-pass.sh", content: "#!/bin/sh\necho '{\"decision\":\"pass\"}'\n")
            let flow = """
            version: flow/v1
            start: gate
            states:
              - id: gate
                type: gate
                run: ./scripts/gate-pass.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: done
                  fail: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, name: "all-unused.yaml", content: flow)
            let run = try runCLI(arguments: [
                "flow", "run", flowPath,
                "--command", "cmd-a",
                "--command", "cmd-b",
                "--no-steer"
            ])
            #expect(run.exitCode == 0)
            #expect(run.stdout.contains("flow.cli.command_unused"))
            #expect(run.stdout.contains("Unused --command entries: 2"))
        }
    }

    @Test("TC-CLI44 agent counter log value should start at 1")
    func testAgentCounterLogValue() async throws {
        try await withTestWorkspace(prefix: "flow-cli-counter-log") { workspace in
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
                    task: one-shot
                    counter: fix_round
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
                #expect(run.exitCode == 0)
                #expect(run.stdout.contains("state_type=agent"))
                #expect(run.stdout.contains("\"name\":\"fix_round\""))
                #expect(run.stdout.contains("\"value\":1"))
            }
        }
    }

    @Test("TC-P05 flow run accepts stdin steer while agent turn is active")
    func testInteractiveSteerViaStdin() async throws {
        try await withTestWorkspace(prefix: "flow-cli-stdin-steer") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            let outputPath = workspace.rootURL.appendingPathComponent("stdin-steer.txt").path
            _ = try workspace.makeScript(
                name: "write.sh",
                content: "#!/bin/sh\necho \"$1\" > \"\(outputPath)\"\n"
            )

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
                    task: stdin-steer
                    export:
                      received: "$.current.final.received"
                    next: write
                  - id: write
                    type: script
                    run: ./scripts/write.sh
                    args:
                      - "$.context.received"
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(
                    arguments: ["flow", "run", flowPath],
                    stdin: "from-stdin\n",
                    timeout: 5
                )
                #expect(run.timedOut == false)
                #expect(run.exitCode == 0)
                let content = try String(contentsOfFile: outputPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(content == "from-stdin")
            }
        }
    }

    @Test("TC-CLI28 --no-steer should disable stdin steer input")
    func testNoSteerDisablesStdinInput() async throws {
        try await withTestWorkspace(prefix: "flow-cli-no-steer-stdin") { workspace in
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
                    task: waiting-command
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(
                    arguments: ["flow", "run", flowPath, "--no-steer"],
                    stdin: "should-be-ignored\n",
                    timeout: 2
                )
                #expect(run.timedOut == true)
            }
        }
    }

    @Test("TC-CLI19/TC-R05/TC-R06 run path and workingDirectory should be flow-dir based and cwd-independent")
    func testRunPathAndWorkingDirectoryAreCWDIndependent() async throws {
        try await withTestWorkspace(prefix: "flow-cli-cwd-independent") { workspace in
            let gatePwdPath = workspace.rootURL.appendingPathComponent("gate-pwd.txt").path
            let scriptPwdPath = workspace.rootURL.appendingPathComponent("script-pwd.txt").path
            _ = try workspace.makeExecutable(
                relativePath: "flows/scripts/gate.sh",
                content: "#!/bin/sh\npwd > \"\(gatePwdPath)\"\necho '{\"decision\":\"pass\"}'\n"
            )
            _ = try workspace.makeExecutable(
                relativePath: "flows/scripts/run.sh",
                content: "#!/bin/sh\npwd > \"\(scriptPwdPath)\"\n"
            )

            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/gate.sh
                on:
                  pass: run
                  needs_agent: done_fail
                  wait: done_fail
                  fail: done_fail
              - id: run
                type: script
                run: ./scripts/run.sh
                next: done
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let flowPath = try workspace.makeFile(relativePath: "flows/flow.yaml", content: flow)
            let outsideCWD = workspace.rootURL.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outsideCWD, withIntermediateDirectories: true)

            let run = try runCLI(
                arguments: ["flow", "run", flowPath, "--no-steer"],
                cwd: outsideCWD.path
            )

            #expect(run.exitCode == 0)
            let expectedCWD = workspace.rootURL
                .appendingPathComponent("flows/scripts")
                .resolvingSymlinksInPath()
                .path
            let gatePwd = URL(fileURLWithPath: try String(contentsOfFile: gatePwdPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ).resolvingSymlinksInPath().path
            let scriptPwd = URL(fileURLWithPath: try String(contentsOfFile: scriptPwdPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ).resolvingSymlinksInPath().path
            #expect(gatePwd == expectedCWD)
            #expect(scriptPwd == expectedCWD)
        }
    }

    @Test("TC-R04 flow gate/script interpreter should map to ScriptRunner interpreter")
    func testFlowInterpreterMappingForGateAndScript() async throws {
        try await withTestWorkspace(prefix: "flow-cli-interpreter-map") { workspace in
            let markerPath = workspace.rootURL.appendingPathComponent("python-marker.txt").path
            _ = try workspace.makeFile(
                relativePath: "scripts/gate.py",
                content: "import json\nprint(json.dumps({\"decision\": \"pass\"}))\n"
            )
            _ = try workspace.makeFile(
                relativePath: "scripts/run.py",
                content: "from pathlib import Path\nPath(\"\(markerPath)\").write_text(\"ok\", encoding=\"utf-8\")\n"
            )

            let flow = """
            version: flow/v1
            start: gate
            states:
              - id: gate
                type: gate
                run: ./scripts/gate.py
                interpreter: python3
                on:
                  pass: run
                  needs_agent: done_fail
                  wait: done_fail
                  fail: done_fail
              - id: run
                type: script
                run: ./scripts/run.py
                interpreter: python3
                next: done
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
            #expect(run.exitCode == 0)
            let marker = try String(contentsOfFile: markerPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(marker == "ok")
        }
    }

    @Test("TC-CLI13 flow run step timeout should return timeout code with failed state")
    func testCLIStepTimeoutCodeAndStateID() async throws {
        try await withTestWorkspace(prefix: "flow-cli-step-timeout") { workspace in
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
            let flowPath = try writeFlowFile(workspace: workspace, name: "step-timeout.yaml", content: flow)
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("flow.step.timeout"))
            #expect(run.stdout.contains("state_id=run"))
        }
    }

    @Test("TC-CLI37 wait timeout should return flow.step.timeout")
    func testCLIWaitTimeoutCode() async throws {
        try await withTestWorkspace(prefix: "flow-cli-wait-timeout") { workspace in
            let flow = """
            version: flow/v1
            start: hold
            states:
              - id: hold
                type: wait
                seconds: 2
                timeout_sec: 1
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, name: "wait-timeout.yaml", content: flow)
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("flow.step.timeout"))
            #expect(run.stdout.contains("state_id=hold"))
        }
    }

    @Test("TC-CLI41 gate process non-zero should return flow.gate.process_exit_nonzero")
    func testCLIGateProcessExitNonZeroCode() async throws {
        try await withTestWorkspace(prefix: "flow-cli-gate-exit-nonzero") { workspace in
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
            let flowPath = try writeFlowFile(workspace: workspace, name: "gate-exit.yaml", content: flow)
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("flow.gate.process_exit_nonzero"))
            #expect(run.stdout.contains("state_id=gate"))
        }
    }

    @Test("TC-CLI32/TC-CLI34/TC-CLI35 command queue should preserve FIFO and retry next turn")
    func testCommandQueueFIFOAndRetryAcrossTurns() async throws {
        try await withTestWorkspace(prefix: "flow-cli-command-fifo-retry") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            let outputPath = workspace.rootURL.appendingPathComponent("command-order.txt").path
            _ = try workspace.makeScript(
                name: "write-order.sh",
                content: "#!/bin/sh\necho \"$1|$2\" > \"\(outputPath)\"\n"
            )

            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "wait_for_command_single_accept_json"
            ]) {
                let flow = """
                version: flow/v1
                start: first
                defaults:
                  step_timeout_sec: 5
                states:
                  - id: first
                    type: agent
                    task: first-turn
                    timeout_sec: 5
                    export:
                      first_cmd: "$.current.final.received"
                    next: second
                  - id: second
                    type: agent
                    task: second-turn
                    timeout_sec: 5
                    export:
                      second_cmd: "$.current.final.received"
                    next: write
                  - id: write
                    type: script
                    run: ./scripts/write-order.sh
                    args:
                      - "$.context.first_cmd"
                      - "$.context.second_cmd"
                    next: done
                  - id: done
                    type: end
                    status: success
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(arguments: [
                    "flow", "run", flowPath,
                    "--command", "first",
                    "--command", "second",
                    "--no-steer"
                ])

                #expect(run.exitCode == 0)
                #expect(run.stdout.contains("flow.cli.command_unused") == false)
                let content = try String(contentsOfFile: outputPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(content == "first|second")
            }
        }
    }

    @Test("TC-CLI33 command queued before first agent turn should not be lost")
    func testCommandQueuedBeforeFirstAgentTurn() async throws {
        try await withTestWorkspace(prefix: "flow-cli-command-pre-agent") { workspace in
            let codexPath = try workspace.makeFakeCodex()
            let outputPath = workspace.rootURL.appendingPathComponent("queued-before-agent.txt").path
            _ = try workspace.makeScript(name: "gate.sh", content: "#!/bin/sh\necho '{\"decision\":\"needs_agent\"}'\n")
            _ = try workspace.makeScript(
                name: "write.sh",
                content: "#!/bin/sh\necho \"$1\" > \"\(outputPath)\"\n"
            )

            try await withEnvironment([
                "SCRIPTORIA_CODEX_EXECUTABLE": codexPath,
                "SCRIPTORIA_FAKE_CODEX_MODE": "wait_for_command_json"
            ]) {
                let flow = """
                version: flow/v1
                start: gate
                defaults:
                  step_timeout_sec: 2
                states:
                  - id: gate
                    type: gate
                    run: ./scripts/gate.sh
                    on:
                      pass: done_fail
                      needs_agent: fix
                      wait: done_fail
                      fail: done_fail
                  - id: fix
                    type: agent
                    task: queued-command
                    timeout_sec: 2
                    export:
                      received: "$.current.final.received"
                    next: write
                  - id: write
                    type: script
                    run: ./scripts/write.sh
                    args:
                      - "$.context.received"
                    next: done
                  - id: done
                    type: end
                    status: success
                  - id: done_fail
                    type: end
                    status: failure
                """
                let flowPath = try writeFlowFile(workspace: workspace, content: flow)
                let run = try runCLI(arguments: [
                    "flow", "run", flowPath,
                    "--command", "queued-before-agent",
                    "--no-steer"
                ])
                #expect(run.exitCode == 0)
                let content = try String(contentsOfFile: outputPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(content == "queued-before-agent")
            }
        }
    }

    @Test("TC-CLI39/TC-CLI40 runtime log field contract")
    func testRuntimeLogFieldContract() async throws {
        try await withTestWorkspace(prefix: "flow-cli-log-contract") { workspace in
            _ = try workspace.makeScript(name: "ok.sh", content: "#!/bin/sh\necho ok\n")
            let successFlow = """
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
            let successPath = try writeFlowFile(workspace: workspace, name: "log-success.yaml", content: successFlow)
            let successRun = try runCLI(arguments: ["flow", "run", successPath, "--no-steer"])
            #expect(successRun.exitCode == 0)
            #expect(successRun.stdout.contains("phase=runtime"))
            #expect(successRun.stdout.contains("state_type=script"))
            #expect(successRun.stdout.contains("attempt=1"))
            #expect(successRun.stdout.contains("counter=null"))
            #expect(successRun.stdout.contains("decision=null"))
            #expect(successRun.stdout.contains("duration="))

            _ = try workspace.makeScript(name: "fail.sh", content: "#!/bin/sh\nexit 8\n")
            let failureFlow = """
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
            let failurePath = try writeFlowFile(workspace: workspace, name: "log-failure.yaml", content: failureFlow)
            let failureRun = try runCLI(arguments: ["flow", "run", failurePath, "--no-steer"])
            #expect(failureRun.exitCode != 0)
            #expect(failureRun.stdout.contains("phase=runtime"))
            #expect(failureRun.stdout.contains("state_id=run"))
            #expect(failureRun.stdout.contains("transition=null"))
            #expect(failureRun.stdout.contains("error_code=flow.script.process_exit_nonzero"))
            #expect(failureRun.stdout.contains("error_message="))
        }
    }
}
