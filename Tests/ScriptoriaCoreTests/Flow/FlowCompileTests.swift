import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow Compile", .serialized)
struct FlowCompileTests {
    @Test("TC-C01/TC-C02/TC-C08 compile injects defaults and preserves states")
    func testCompileInjectsDefaults() async throws {
        try await withTestWorkspace(prefix: "flow-compile-defaults") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let ir = try FlowCompiler.compileFile(atPath: flowPath)

            #expect(ir.version == "flow-ir/v1")
            #expect(ir.start == "precheck")
            #expect(ir.defaults.maxAgentRounds == 20)
            #expect(ir.defaults.maxWaitCycles == 200)
            #expect(ir.defaults.maxTotalSteps == 2000)
            #expect(ir.defaults.stepTimeoutSec == 1800)
            #expect(ir.states.map(\.id) == ["precheck", "wait1", "fix", "done", "done_fail"])
        }
    }

    @Test("TC-C03/TC-C07 canonical compile output is deterministic")
    func testCanonicalOutputDeterministic() async throws {
        try await withTestWorkspace(prefix: "flow-compile-canonical") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())

            let ir1 = try FlowCompiler.compileFile(atPath: flowPath)
            let json1 = try FlowCompiler.renderCanonicalJSON(ir: ir1)

            let ir2 = try FlowCompiler.compileFile(atPath: flowPath)
            let json2 = try FlowCompiler.renderCanonicalJSON(ir: ir2)

            #expect(json1 == json2)
        }
    }

    @Test("TC-C11/TC-C12/TC-C17 relative run path is normalized and cwd-independent")
    func testPathNormalizationAndCwdIndependence() async throws {
        try await withTestWorkspace(prefix: "flow-compile-path") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = minimalFlowYAML(runPath: "./scripts/./check.sh")
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)

            let ir1 = try FlowCompiler.compileFile(atPath: flowPath)
            let json1 = try FlowCompiler.renderCanonicalJSON(ir: ir1)

            let otherCwd = workspace.rootURL.appendingPathComponent("another-cwd")
            try FileManager.default.createDirectory(at: otherCwd, withIntermediateDirectories: true)
            let previous = FileManager.default.currentDirectoryPath
            defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
            _ = FileManager.default.changeCurrentDirectoryPath(otherCwd.path)

            let ir2 = try FlowCompiler.compileFile(atPath: flowPath)
            let json2 = try FlowCompiler.renderCanonicalJSON(ir: ir2)

            #expect(json1 == json2)
            let precheck = try #require(ir2.states.first(where: { $0.id == "precheck" }))
            #expect(precheck.exec?.run == "scripts/check.sh")
        }
    }

    @Test("TC-C14/TC-C15 no-fs-check behavior")
    func testCompileNoFileSystemCheck() async throws {
        try await withTestWorkspace(prefix: "flow-compile-fs-check") { workspace in
            let flow = minimalFlowYAML(runPath: "./scripts/missing.sh")
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)

            requireFlowErrorSync("flow.path.not_found") {
                _ = try FlowCompiler.compileFile(atPath: flowPath)
            }

            let ir = try FlowCompiler.compileFile(atPath: flowPath, options: .init(checkFileSystem: false))
            let precheck = try #require(ir.states.first(where: { $0.id == "precheck" }))
            #expect(precheck.exec?.run == "scripts/missing.sh")
        }
    }

    @Test("TC-C16 bare token still fails even with no-fs-check")
    func testNoFSCheckStillValidatesPathKind() async throws {
        try await withTestWorkspace(prefix: "flow-compile-no-fs-path-kind") { workspace in
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML(runPath: "check.sh"))
            requireFlowErrorSync("flow.path.invalid_path_kind") {
                _ = try FlowCompiler.compileFile(atPath: flowPath, options: .init(checkFileSystem: false))
            }
        }
    }

    @Test("TC-C18 args/env number-bool literal stringify in IR")
    func testLiteralStringificationInIR() async throws {
        try await withTestWorkspace(prefix: "flow-compile-stringify") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                args:
                  - 42
                  - true
                env:
                  FLAG: false
                  COUNT: 9
                on:
                  pass: done
                  needs_agent: fix
                  wait: wait1
                  fail: done_fail
              - id: wait1
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
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let precheck = try #require(ir.states.first(where: { $0.id == "precheck" }))
            #expect(precheck.exec?.args == ["42", "true"])
            #expect(precheck.exec?.env["FLAG"] == "false")
            #expect(precheck.exec?.env["COUNT"] == "9")
        }
    }

    @Test("TC-C09 expression syntax invalid should fail at compile")
    func testCompileRejectsMalformedExpression() async throws {
        try await withTestWorkspace(prefix: "flow-compile-expr-malformed") { workspace in
            _ = try workspace.makeScript(name: "echo.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/echo.sh
                args:
                  - "$.context."
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowCompiler.compileFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-C10 unsupported expression scope prefix should fail at compile")
    func testCompileRejectsUnsupportedExpressionPrefix() async throws {
        try await withTestWorkspace(prefix: "flow-compile-expr-prefix") { workspace in
            _ = try workspace.makeScript(name: "echo.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/echo.sh
                args:
                  - "$.foo.value"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowCompiler.compileFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-C19 wait.timeout_sec should be preserved in IR")
    func testWaitTimeoutSecInIR() async throws {
        try await withTestWorkspace(prefix: "flow-compile-wait-timeout") { workspace in
            let flow = """
            version: flow/v1
            start: hold
            defaults:
              step_timeout_sec: 30
            states:
              - id: hold
                type: wait
                seconds: 1
                timeout_sec: 9
                next: hold2
              - id: hold2
                type: wait
                seconds: 1
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let hold = try #require(ir.states.first(where: { $0.id == "hold" }))
            let hold2 = try #require(ir.states.first(where: { $0.id == "hold2" }))
            #expect(hold.wait?.timeoutSec == 9)
            #expect(hold2.wait?.timeoutSec == 30)
        }
    }

    @Test("TC-C04 expression fields should be preserved in IR")
    func testExpressionFieldsPreservedInIR() async throws {
        try await withTestWorkspace(prefix: "flow-compile-expr-preserve") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            _ = try workspace.makeScript(name: "run.sh", content: "#!/bin/sh\necho '{\"value\":\"x\"}'\n")
            let flow = """
            version: flow/v1
            start: precheck
            context:
              name: dev
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                args:
                  - "$.context.name"
                on:
                  pass: run
                  needs_agent: done
                  wait: done
                  fail: done
              - id: run
                type: script
                run: ./scripts/run.sh
                args:
                  - "$.state.precheck.last.decision"
                export:
                  v: "$.current.final.value"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let precheck = try #require(ir.states.first(where: { $0.id == "precheck" }))
            let run = try #require(ir.states.first(where: { $0.id == "run" }))
            #expect(precheck.exec?.args == ["$.context.name"])
            #expect(run.exec?.args == ["$.state.precheck.last.decision"])
            #expect(run.export?["v"] == "$.current.final.value")
        }
    }

    @Test("TC-C05 compile errors should include state context and field path")
    func testCompileErrorContainsStateAndFieldPath() async throws {
        try await withTestWorkspace(prefix: "flow-compile-error-context") { workspace in
            _ = try workspace.makeScript(name: "run.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/run.sh
                args:
                  - "$.state.run.output"
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            do {
                _ = try FlowCompiler.compileFile(atPath: flowPath)
                Issue.record("Expected compile to fail")
            } catch let error as FlowError {
                #expect(error.code == "flow.validate.schema_error")
                #expect(error.fieldPath?.contains("states.run.args") == true)
                #expect(error.message.contains("state expression must use .last"))
            }
        }
    }

    @Test("TC-C06 canonical JSON should match minimal golden")
    func testCanonicalJSONMatchesGolden() async throws {
        try await withTestWorkspace(prefix: "flow-compile-golden") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let ir = try FlowCompiler.compileFile(atPath: flowPath)
            let json = try FlowCompiler.renderCanonicalJSON(ir: ir)
                .replacingOccurrences(of: "\\/", with: "/")

            let golden = """
            {
              "context" : {

              },
              "defaults" : {
                "failOnParseError" : true,
                "maxAgentRounds" : 20,
                "maxTotalSteps" : 2000,
                "maxWaitCycles" : 200,
                "stepTimeoutSec" : 1800
              },
              "start" : "precheck",
              "states" : [
                {
                  "exec" : {
                    "args" : [

                    ],
                    "env" : {

                    },
                    "interpreter" : "auto",
                    "parse" : "json_last_line",
                    "run" : "scripts/check.sh",
                    "timeout_sec" : 1800
                  },
                  "id" : "precheck",
                  "kind" : "gate",
                  "transitions" : {
                    "fail" : "done_fail",
                    "needs_agent" : "fix",
                    "pass" : "done",
                    "wait" : "wait1"
                  }
                },
                {
                  "id" : "wait1",
                  "kind" : "wait",
                  "next" : "precheck",
                  "wait" : {
                    "seconds" : 0,
                    "timeout_sec" : 1800
                  }
                },
                {
                  "agent" : {
                    "counter" : "agent_round.fix",
                    "max_rounds" : 20,
                    "task" : "fix",
                    "timeout_sec" : 1800
                  },
                  "id" : "fix",
                  "kind" : "agent",
                  "next" : "done"
                },
                {
                  "end" : {
                    "status" : "success"
                  },
                  "id" : "done",
                  "kind" : "end"
                },
                {
                  "end" : {
                    "status" : "failure"
                  },
                  "id" : "done_fail",
                  "kind" : "end"
                }
              ],
              "version" : "flow-ir/v1"
            }
            """
            #expect(json == golden)
        }
    }

    @Test("TC-C13 compile should reject bare command run token")
    func testCompileRejectsBareCommandToken() async throws {
        try await withTestWorkspace(prefix: "flow-compile-path-kind-default") { workspace in
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML(runPath: "eslint"))
            requireFlowErrorSync("flow.path.invalid_path_kind") {
                _ = try FlowCompiler.compileFile(atPath: flowPath)
            }
        }
    }
}
