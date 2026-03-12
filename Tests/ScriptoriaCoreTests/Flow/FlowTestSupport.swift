import Foundation
import Testing
@testable import ScriptoriaCore

func writeFlowFile(workspace: TestWorkspace, name: String = "flow.yaml", content: String) throws -> String {
    try workspace.makeFile(relativePath: name, content: content)
}

func writeFixtureFile(workspace: TestWorkspace, name: String = "fixture.json", json: String) throws -> String {
    try workspace.makeFile(relativePath: "fixtures/\(name)", content: json)
}

func requireFlowError(
    _ expectedCode: String,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected FlowError with code \(expectedCode), but operation succeeded.")
    } catch let error as FlowError {
        #expect(error.code == expectedCode)
    } catch {
        Issue.record("Expected FlowError with code \(expectedCode), got \(error)")
    }
}

func requireFlowErrorSync(
    _ expectedCode: String,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected FlowError with code \(expectedCode), but operation succeeded.")
    } catch let error as FlowError {
        #expect(error.code == expectedCode)
    } catch {
        Issue.record("Expected FlowError with code \(expectedCode), got \(error)")
    }
}

func minimalFlowYAML(runPath: String = "./scripts/check.sh") -> String {
    """
    version: flow/v1
    start: precheck
    states:
      - id: precheck
        type: gate
        run: \(runPath)
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
}
