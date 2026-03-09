import Testing
import Foundation
@testable import ScriptoriaCore

@Test func testScriptCreation() {
    let script = Script(
        title: "Test Script",
        description: "A test script",
        path: "/tmp/test.sh",
        interpreter: .bash,
        tags: ["test"]
    )

    #expect(script.title == "Test Script")
    #expect(script.interpreter == .bash)
    #expect(script.tags == ["test"])
    #expect(script.runCount == 0)
    #expect(script.lastRunStatus == nil)
}

@Test func testInterpreterDetection() {
    let runner = ScriptRunner()

    #expect(runner.detectInterpreter(for: "/tmp/test.sh") == .sh)
    #expect(runner.detectInterpreter(for: "/tmp/test.bash") == .bash)
    #expect(runner.detectInterpreter(for: "/tmp/test.js") == .node)
    #expect(runner.detectInterpreter(for: "/tmp/test.py") == .python3)
    #expect(runner.detectInterpreter(for: "/tmp/test.rb") == .ruby)
    #expect(runner.detectInterpreter(for: "/tmp/test.zsh") == .zsh)
    #expect(runner.detectInterpreter(for: "/tmp/test.applescript") == .osascript)
}

@Test func testScriptStoreSearchAndFilter() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("scriptoria-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = ScriptStore(baseDirectory: tmpDir.path)
    try await store.load()

    let script1 = Script(title: "Deploy App", description: "Deploy to production", path: "/tmp/deploy.sh", tags: ["deploy", "prod"])
    let script2 = Script(title: "Backup DB", description: "Backup database", path: "/tmp/backup.sh", tags: ["backup", "db"])
    let script3 = Script(title: "Clean Logs", description: "Remove old logs", path: "/tmp/clean.sh", tags: ["cleanup"])

    try await store.add(script1)
    try await store.add(script2)
    try await store.add(script3)

    // Search
    #expect(store.search(query: "deploy").count == 1)
    #expect(store.search(query: "backup").count == 1)
    #expect(store.search(query: "app").count == 1)  // matches "Deploy App"

    // Filter by tag
    #expect(store.filter(tag: "deploy").count == 1)
    #expect(store.filter(tag: "db").count == 1)

    // All tags
    let tags = store.allTags()
    #expect(tags.count == 5)

    // All scripts
    #expect(store.all().count == 3)
}

@Test func testScriptRunRecord() {
    let run = ScriptRun(
        scriptId: UUID(),
        scriptTitle: "Test",
        startedAt: Date(),
        finishedAt: Date().addingTimeInterval(2.5),
        status: .success,
        exitCode: 0,
        output: "Hello World\n"
    )

    #expect(run.status == .success)
    #expect(run.exitCode == 0)
    #expect(run.duration != nil)
    #expect(run.duration! > 2.0)
}
