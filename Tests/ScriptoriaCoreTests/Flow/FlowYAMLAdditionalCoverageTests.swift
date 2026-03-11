import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow YAML Additional Coverage", .serialized)
struct FlowYAMLAdditionalCoverageTests {
    @Test("TC-Y02/TC-Y04 missing required top-level fields should fail")
    func testMissingRequiredTopLevelFields() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-missing-top-fields") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")

            let missingVersion = """
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: done
                  fail: done
              - id: done
                type: end
                status: success
            """
            let missingVersionPath = try writeFlowFile(workspace: workspace, name: "missing-version.yaml", content: missingVersion)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: missingVersionPath)
            }

            let missingStart = """
            version: flow/v1
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                on:
                  pass: done
                  needs_agent: done
                  wait: done
                  fail: done
              - id: done
                type: end
                status: success
            """
            let missingStartPath = try writeFlowFile(workspace: workspace, name: "missing-start.yaml", content: missingStart)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: missingStartPath)
            }
        }
    }

    @Test("TC-Y06 invalid state type should fail")
    func testInvalidStateType() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-invalid-type") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            let flow = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: checker
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y12 wait missing seconds and seconds_from should fail")
    func testWaitMissingSecondsSource() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-wait-missing-seconds") { workspace in
            let flow = """
            version: flow/v1
            start: hold
            states:
              - id: hold
                type: wait
                next: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y14 jump target missing should fail")
    func testMissingTransitionTarget() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-missing-target") { workspace in
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
                  needs_agent: ghost
                  wait: done
                  fail: done
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y18 script missing run/next should fail")
    func testScriptMissingRequiredFields() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-script-missing-fields") { workspace in
            let missingRun = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                next: done
              - id: done
                type: end
                status: success
            """
            let missingRunPath = try writeFlowFile(workspace: workspace, name: "missing-run.yaml", content: missingRun)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: missingRunPath)
            }

            _ = try workspace.makeScript(name: "ok.sh", content: "#!/bin/sh\necho ok\n")
            let missingNext = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/ok.sh
              - id: done
                type: end
                status: success
            """
            let missingNextPath = try writeFlowFile(workspace: workspace, name: "missing-next.yaml", content: missingNext)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: missingNextPath)
            }
        }
    }

    @Test("TC-Y20/TC-Y35 states schema damage should fail")
    func testStatesSchemaDamage() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-states-schema") { workspace in
            let statesMap = """
            version: flow/v1
            start: done
            states:
              done:
                type: end
                status: success
            """
            let statesMapPath = try writeFlowFile(workspace: workspace, name: "states-map.yaml", content: statesMap)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: statesMapPath)
            }

            let statesScalar = """
            version: flow/v1
            start: done
            states: nope
            """
            let statesScalarPath = try writeFlowFile(workspace: workspace, name: "states-scalar.yaml", content: statesScalar)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: statesScalarPath)
            }
        }
    }

    @Test("TC-Y21 duplicate state id should fail")
    func testDuplicateStateID() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-duplicate-id") { workspace in
            let flow = """
            version: flow/v1
            start: done
            states:
              - id: done
                type: end
                status: success
              - id: done
                type: end
                status: success
            """
            let flowPath = try writeFlowFile(workspace: workspace, content: flow)
            requireFlowErrorSync("flow.validate.schema_error") {
                _ = try FlowValidator.validateFile(atPath: flowPath)
            }
        }
    }

    @Test("TC-Y24/TC-Y25/TC-Y26/TC-Y27/TC-Y28/TC-Y29/TC-Y30 numeric constraints should fail")
    func testNumericConstraintFailures() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-numeric-constraints") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")

            let cases: [(String, String)] = [
                ("defaults-max-wait-cycles", """
                version: flow/v1
                start: precheck
                defaults:
                  max_wait_cycles: 0
                states:
                  - id: precheck
                    type: gate
                    run: ./scripts/check.sh
                    on:
                      pass: done
                      needs_agent: done
                      wait: done
                      fail: done
                  - id: done
                    type: end
                    status: success
                """),
                ("defaults-max-total-steps", """
                version: flow/v1
                start: precheck
                defaults:
                  max_total_steps: 0
                states:
                  - id: precheck
                    type: gate
                    run: ./scripts/check.sh
                    on:
                      pass: done
                      needs_agent: done
                      wait: done
                      fail: done
                  - id: done
                    type: end
                    status: success
                """),
                ("defaults-step-timeout", """
                version: flow/v1
                start: precheck
                defaults:
                  step_timeout_sec: 0
                states:
                  - id: precheck
                    type: gate
                    run: ./scripts/check.sh
                    on:
                      pass: done
                      needs_agent: done
                      wait: done
                      fail: done
                  - id: done
                    type: end
                    status: success
                """),
                ("agent-max-rounds", """
                version: flow/v1
                start: fix
                states:
                  - id: fix
                    type: agent
                    task: fix
                    max_rounds: 0
                    next: done
                  - id: done
                    type: end
                    status: success
                """),
                ("state-timeout", """
                version: flow/v1
                start: hold
                states:
                  - id: hold
                    type: wait
                    seconds: 1
                    timeout_sec: 0
                    next: done
                  - id: done
                    type: end
                    status: success
                """),
                ("wait-seconds-negative", """
                version: flow/v1
                start: hold
                states:
                  - id: hold
                    type: wait
                    seconds: -1
                    next: done
                  - id: done
                    type: end
                    status: success
                """),
                ("wait-seconds-non-integer", """
                version: flow/v1
                start: hold
                states:
                  - id: hold
                    type: wait
                    seconds: 1.5
                    next: done
                  - id: done
                    type: end
                    status: success
                """),
            ]

            for (name, content) in cases {
                let flowPath = try writeFlowFile(workspace: workspace, name: "\(name).yaml", content: content)
                requireFlowErrorSync("flow.validate.numeric_range_error") {
                    _ = try FlowValidator.validateFile(atPath: flowPath)
                }
            }
        }
    }

    @Test("TC-Y32/TC-Y33 args-env null-array-object literal should fail")
    func testArgsEnvComplexLiteralRejection() async throws {
        try await withTestWorkspace(prefix: "flow-yaml-args-env-complex") { workspace in
            _ = try workspace.makeScript(name: "check.sh", content: "#!/bin/sh\necho ok\n")
            _ = try workspace.makeScript(name: "run.sh", content: "#!/bin/sh\necho ok\n")

            let gateEnvObject = """
            version: flow/v1
            start: precheck
            states:
              - id: precheck
                type: gate
                run: ./scripts/check.sh
                env:
                  BAD:
                    x: 1
                on:
                  pass: done
                  needs_agent: done
                  wait: done
                  fail: done
              - id: done
                type: end
                status: success
            """
            let gatePath = try writeFlowFile(workspace: workspace, name: "gate-env-object.yaml", content: gateEnvObject)
            requireFlowErrorSync("flow.validate.field_type_error") {
                _ = try FlowValidator.validateFile(atPath: gatePath)
            }

            let scriptArgsArray = """
            version: flow/v1
            start: run
            states:
              - id: run
                type: script
                run: ./scripts/run.sh
                args:
                  - [1, 2]
                next: done
              - id: done
                type: end
                status: success
            """
            let scriptPath = try writeFlowFile(workspace: workspace, name: "script-args-array.yaml", content: scriptArgsArray)
            requireFlowErrorSync("flow.validate.field_type_error") {
                _ = try FlowValidator.validateFile(atPath: scriptPath)
            }
        }
    }
}
