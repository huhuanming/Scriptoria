import Foundation
import Testing
@testable import ScriptoriaCore

@Suite("Flow PR Gate Scenarios", .serialized)
struct FlowPRGateScenarioTests {
    @Test("TC-PR01 CI success + no blocking comments -> pass")
    func testPRScenarioPass() throws {
        let stdout = #"{"decision":"pass","ci_status":"success","blocking_comments":0}"#
        let parsed = try FlowGateOutputParser.parse(stdout: stdout, mode: .jsonLastLine)
        #expect(parsed.decision == .pass)
    }

    @Test("TC-PR02 CI failure -> needs_agent")
    func testPRScenarioNeedsAgentByCIFailure() throws {
        let stdout = #"{"decision":"needs_agent","ci_status":"failure"}"#
        let parsed = try FlowGateOutputParser.parse(stdout: stdout, mode: .jsonLastLine)
        #expect(parsed.decision == .needsAgent)
    }

    @Test("TC-PR03 CI pending -> wait")
    func testPRScenarioWaitByCIPending() throws {
        let stdout = #"{"decision":"wait","ci_status":"pending","retry_after_sec":30}"#
        let parsed = try FlowGateOutputParser.parse(stdout: stdout, mode: .jsonLastLine)
        #expect(parsed.decision == .wait)
        #expect(parsed.retryAfterSec == 30)
    }

    @Test("TC-PR04 request changes review -> needs_agent")
    func testPRScenarioNeedsAgentByReview() throws {
        let stdout = #"{"decision":"needs_agent","review_state":"REQUEST_CHANGES"}"#
        let parsed = try FlowGateOutputParser.parse(stdout: stdout, mode: .jsonLastLine)
        #expect(parsed.decision == .needsAgent)
    }

    @Test("TC-PR05 missing PR URL -> fail")
    func testPRScenarioFailWhenPRURLMissing() throws {
        let stdout = #"{"decision":"fail","reason":"pr_url_missing"}"#
        let parsed = try FlowGateOutputParser.parse(stdout: stdout, mode: .jsonLastLine)
        #expect(parsed.decision == .fail)
    }
}
