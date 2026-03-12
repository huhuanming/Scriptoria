import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Gate Output Parser")
struct GateOutputParserTests {
    @Test("TC-GP01/TC-GP02/TC-GP03/TC-GP04 parse all legal decisions")
    func testParseDecisions() throws {
        let pass = try FlowGateOutputParser.parse(
            stdout: "log\n{\"decision\":\"pass\",\"reason\":\"ok\"}\n",
            mode: .jsonLastLine
        )
        #expect(pass.decision == .pass)

        let needsAgent = try FlowGateOutputParser.parse(
            stdout: "{\"decision\":\"needs_agent\"}\n",
            mode: .jsonLastLine
        )
        #expect(needsAgent.decision == .needsAgent)

        let wait = try FlowGateOutputParser.parse(
            stdout: "{\"decision\":\"wait\",\"retry_after_sec\":3}\n",
            mode: .jsonLastLine
        )
        #expect(wait.decision == .wait)
        #expect(wait.retryAfterSec == 3)

        let fail = try FlowGateOutputParser.parse(
            stdout: "{\"decision\":\"fail\"}\n",
            mode: .jsonLastLine
        )
        #expect(fail.decision == .fail)
    }

    @Test("TC-GP05/TC-GP06/TC-GP07/TC-GP08 invalid gate output should throw parse_error")
    func testInvalidGateOutput() {
        requireFlowErrorSync("flow.gate.parse_error") {
            _ = try FlowGateOutputParser.parse(stdout: "not-json\n", mode: .jsonLastLine)
        }

        requireFlowErrorSync("flow.gate.parse_error") {
            _ = try FlowGateOutputParser.parse(stdout: "{}\n", mode: .jsonLastLine)
        }

        requireFlowErrorSync("flow.gate.parse_error") {
            _ = try FlowGateOutputParser.parse(stdout: "{\"decision\":\"unknown\"}\n", mode: .jsonLastLine)
        }

        requireFlowErrorSync("flow.gate.parse_error") {
            _ = try FlowGateOutputParser.parse(
                stdout: "{\"decision\":\"wait\",\"retry_after_sec\":\"abc\"}\n",
                mode: .jsonLastLine
            )
        }
    }

    @Test("TC-GP12/TC-GP13 parse json_full_stdout mode")
    func testJsonFullStdoutMode() {
        do {
            let parsed = try FlowGateOutputParser.parse(
                stdout: "{\"decision\":\"pass\",\"meta\":{\"a\":1}}",
                mode: .jsonFullStdout
            )
            #expect(parsed.decision == .pass)
        } catch {
            Issue.record("Expected valid json_full_stdout parse, got \(error)")
        }

        requireFlowErrorSync("flow.gate.parse_error") {
            _ = try FlowGateOutputParser.parse(
                stdout: "prefix\n{\"decision\":\"pass\"}",
                mode: .jsonFullStdout
            )
        }
    }
}
