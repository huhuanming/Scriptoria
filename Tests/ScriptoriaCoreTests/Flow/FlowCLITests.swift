import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow CLI", .serialized)
struct FlowCLITests {
    @Test("TC-CLI01/TC-CLI03 flow validate and compile")
    func testFlowValidateAndCompile() async throws {
        try await withTestWorkspace(prefix: "flow-cli-validate-compile") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let outPath = workspace.rootURL.appendingPathComponent("compiled/flow.json").path

            let validate = try runCLI(arguments: ["flow", "validate", flowPath])
            #expect(validate.exitCode == 0)
            #expect(validate.stdout.contains("flow validate ok"))

            let compile = try runCLI(arguments: ["flow", "compile", flowPath, "--out", outPath])
            #expect(compile.exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: outPath))
            let compiled = try String(contentsOfFile: outPath, encoding: .utf8)
            #expect(compiled.contains("\"version\""))
            #expect(compiled.contains("flow-ir"))
        }
    }

    @Test("TC-CLI02 flow validate invalid file should fail")
    func testFlowValidateInvalidFile() async throws {
        try await withTestWorkspace(prefix: "flow-cli-validate-invalid") { workspace in
            let invalidPath = try writeFlowFile(
                workspace: workspace,
                name: "invalid.yaml",
                content: "version: flow/v1\nstart: x\nstates: ["
            )
            let validate = try runCLI(arguments: ["flow", "validate", invalidPath])
            #expect(validate.exitCode != 0)
            #expect(validate.stdout.contains("flow.validate.schema_error"))
        }
    }

    @Test("TC-CLI20/TC-CLI21 validate and compile allow --no-fs-check")
    func testNoFSCheckCommands() async throws {
        try await withTestWorkspace(prefix: "flow-cli-no-fs") { workspace in
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML(runPath: "./scripts/missing.sh"))
            let outPath = workspace.rootURL.appendingPathComponent("compiled/flow.json").path

            let validate = try runCLI(arguments: ["flow", "validate", flowPath, "--no-fs-check"])
            #expect(validate.exitCode == 0)

            let compile = try runCLI(arguments: ["flow", "compile", flowPath, "--out", outPath, "--no-fs-check"])
            #expect(compile.exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: outPath))
        }
    }

    @Test("TC-CLI23 invalid --var key should fail")
    func testInvalidVarKey() async throws {
        try await withTestWorkspace(prefix: "flow-cli-var-key") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())

            let run = try runCLI(arguments: ["flow", "run", flowPath, "--var", "a.b=1", "--no-steer"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("flow.cli.var_key_invalid"))
        }
    }

    @Test("TC-CLI08/TC-CLI24 duplicate --var uses last value")
    func testDuplicateVarLastWins() async throws {
        try await withTestWorkspace(prefix: "flow-cli-var-last-wins") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho '{\"decision\":\"pass\"}'\n")
            let outPath = workspace.rootURL.appendingPathComponent("var-output.txt").path
            let flow = """
            version: flow/v1
            start: precheck
            context:
              name: old
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: report
                  needs_agent: report
                  wait: report
                  fail: done_fail
              - id: report
                type: script
                run: ./scripts/report.sh
                args:
                  - "$.context.name"
                next: done
              - id: done
                type: end
                status: success
              - id: done_fail
                type: end
                status: failure
            """
            _ = try workspace.makeScript(name: "report.sh", content: "#!/bin/sh\necho \"$1\" > \"\(outPath)\"\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)

            let run = try runCLI(arguments: [
                "flow", "run", flowPath,
                "--var", "name=alice",
                "--var", "name=bob",
                "--no-steer"
            ])
            #expect(run.exitCode == 0)
            let content = try String(contentsOfFile: outPath, encoding: .utf8)
            #expect(content.trimmingCharacters(in: .whitespacesAndNewlines) == "bob")
        }
    }

    @Test("TC-CLI30/TC-CLI38 preflight path-kind failure should not enter runtime")
    func testPreflightPathKindFailure() async throws {
        try await withTestWorkspace(prefix: "flow-cli-preflight") { workspace in
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML(runPath: "eslint"))
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("phase=runtime-preflight"))
            #expect(run.stdout.contains("flow.path.invalid_path_kind"))
            #expect(run.stdout.contains("phase=runtime state_id=") == false)
        }
    }

    @Test("TC-CLI09/TC-CLI43 dry-run fixture missing state data emits runtime-dry-run")
    func testDryRunFixtureFailurePhase() async throws {
        try await withTestWorkspace(prefix: "flow-cli-dryrun-phase") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let fixturePath = try writeFixtureFile(workspace: workspace, json: "{\"states\":{}}")

            let run = try runCLI(arguments: ["flow", "dry-run", flowPath, "--fixture", fixturePath])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("phase=runtime-dry-run"))
            #expect(run.stdout.contains("flow.dryrun.fixture_missing_state_data"))
        }
    }

    @Test("TC-CLI25 validate --no-fs-check should still reject bare command token")
    func testValidateNoFSCheckStillRejectsBareToken() async throws {
        try await withTestWorkspace(prefix: "flow-cli-validate-no-fs-path-kind") { workspace in
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML(runPath: "eslint"))
            let validate = try runCLI(arguments: ["flow", "validate", flowPath, "--no-fs-check"])
            #expect(validate.exitCode != 0)
            #expect(validate.stdout.contains("flow.path.invalid_path_kind"))
        }
    }

    @Test("TC-CLI42 preflight path-not-found should not enter runtime")
    func testPreflightPathMissingFailure() async throws {
        try await withTestWorkspace(prefix: "flow-cli-preflight-path-missing") { workspace in
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/missing.sh
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
            let run = try runCLI(arguments: ["flow", "run", flowPath, "--no-steer"])
            #expect(run.exitCode != 0)
            #expect(run.stdout.contains("phase=runtime-preflight"))
            #expect(run.stdout.contains("flow.path.not_found"))
            #expect(run.stdout.contains("phase=runtime state_id=") == false)
        }
    }

    @Test("validate errors should include source line number when available")
    func testValidateErrorIncludesLineNumber() async throws {
        try await withTestWorkspace(prefix: "flow-cli-validate-line") { workspace in
            let flow = """
            version: bad/v1
            start: done
            states:
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let validate = try runCLI(arguments: ["flow", "validate", flowPath])
            #expect(validate.exitCode != 0)
            #expect(validate.stdout.contains("flow.validate.schema_error"))
            #expect(validate.stdout.contains("line=1"))
            #expect(validate.stdout.contains("column=10"))
        }
    }

    @Test("compile errors should include source line number when available")
    func testCompileErrorIncludesLineNumber() async throws {
        try await withTestWorkspace(prefix: "flow-cli-compile-line") { workspace in
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                parse: json_unknown
                on:
                  pass: done
                  needs_agent: done
                  wait: done
                  fail: done
              - id: done
                type: end
                status: success
            """
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let outPath = workspace.rootURL.appendingPathComponent("compiled/flow.json").path

            let compile = try runCLI(arguments: ["flow", "compile", flowPath, "--out", outPath])
            #expect(compile.exitCode != 0)
            #expect(compile.stdout.contains("flow.gate.parse_mode_invalid"))
            #expect(compile.stdout.contains("line=7"))
            #expect(compile.stdout.contains("column=12"))
        }
    }
}
