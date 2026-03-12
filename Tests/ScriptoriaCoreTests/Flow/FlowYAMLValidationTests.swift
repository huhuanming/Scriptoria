import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow YAML Validation", .serialized)
struct FlowYAMLValidationTests {
    @Test("TC-Y01 minimal legal flow should pass")
    func testMinimalValidFlow() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-valid") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flowPath = try writeFlowFile(workspace: workspace, content: minimalFlowYAML())
            let definition = try FlowValidator.validateFile(atPath: flowPath)
            #expect(definition.version == "flow/v1")
            #expect(definition.start == "precheck")
            #expect(definition.states.count == 5)
        }
    }

    @Test("TC-Y03 invalid version should fail")
    func testInvalidVersion() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-version") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = minimalFlowYAML().replacingOccurrences(of: "flow/v1", with: "flow/v2")
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y05 start points to unknown state")
    func testUnknownStartState() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-start") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = minimalFlowYAML().replacingOccurrences(of: "start: precheck", with: "start: ghost")
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y07/TC-Y08/TC-Y09/TC-Y10 gate.on missing branch should fail")
    func testGateMissingTransition() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-gate-on") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
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
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y11 wait cannot define both seconds and seconds_from")
    func testWaitBothSecondsAndSecondsFrom() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-wait-both") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
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
                  wait: wait1
                  fail: done_fail
              - id: wait1
                type: wait
                seconds: 0
                seconds_from: "$.context.retry"
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
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y13 invalid end status should fail")
    func testInvalidEndStatus() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-end-status") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = minimalFlowYAML().replacingOccurrences(of: "status: success", with: "status: done")
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y15 unreachable state should fail")
    func testUnreachableState() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-unreachable") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = minimalFlowYAML() + "\n  - id: orphan\n    type: end\n    status: success\n"
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.unreachable_state") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y17 fail_on_parse_error=false requires gate.on.parse_error")
    func testParseErrorBranchRequiredWhenDisabled() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-parse-toggle") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: precheck
            defaults:
              fail_on_parse_error: false
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
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
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y19 run command token should fail path-kind check")
    func testRunBareTokenIsRejected() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-path-kind") { workspace in
            let flow = minimalFlowYAML(runPath: "eslint")
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.path.invalid_path_kind") {
                _ = try FlowValidator.validateFile(atPath: flowPath, options: .init(checkFileSystem: false))
            }
        }
    }

    @Test("TC-Y22 invalid gate parse mode")
    func testInvalidGateParseMode() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-parse-mode") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                parse: yaml
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
            requireFlowErrorSync("flow.gate.parse_mode_invalid") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y23 unknown field should fail")
    func testUnknownField() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-unknown") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = minimalFlowYAML().replacingOccurrences(of: "start: precheck", with: "start: precheck\nbogus: true")
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.unknown_field") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y31 gate args disallow null/array/object literal")
    func testArgsLiteralTypeValidation() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-args-type") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                args:
                  - null
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
            requireFlowErrorSync("flow.validate.field_type_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y16/TC-Y34 numeric range validation")
    func testNumericRangeValidation() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-range") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: precheck
            defaults:
              max_agent_rounds: 0
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
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
            requireFlowErrorSync("flow.validate.numeric_range_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }
}
