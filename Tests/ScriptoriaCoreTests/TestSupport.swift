import Darwin
import Foundation
import Testing

struct CLIResult {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var timedOut: Bool
}

struct TestWorkspace {
    let rootURL: URL
    let defaultDataDir: URL

    init(prefix: String = "scriptoria-tests") throws {
        let fm = FileManager.default
        rootURL = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        defaultDataDir = rootURL.appendingPathComponent("default-data")
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: defaultDataDir, withIntermediateDirectories: true)
    }

    var baseEnvironment: [String: String?] {
        [
            "SCRIPTORIA_DEFAULT_DATA_DIR": defaultDataDir.path,
            "SCRIPTORIA_POINTER_FILE": rootURL.appendingPathComponent("pointer.json").path,
            "SCRIPTORIA_DATA_DIR": nil,
            "SCRIPTORIA_LAUNCH_AGENTS_DIR": nil,
            "SCRIPTORIA_LAUNCHCTL_PATH": nil,
            "SCRIPTORIA_FAKE_LAUNCHCTL_LOG": nil,
            "SCRIPTORIA_CODEX_EXECUTABLE": nil,
            "SCRIPTORIA_FAKE_CODEX_MODE": nil,
            "SCRIPTORIA_FAKE_CODEX_THREAD_ID": nil,
            "SCRIPTORIA_FAKE_CODEX_TURN_ID": nil,
            "SCRIPTORIA_FAKE_CODEX_PID_FILE": nil
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeScript(name: String, content: String, executable: Bool = true) throws -> String {
        let scriptDir = rootURL.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        let scriptURL = scriptDir.appendingPathComponent(name)
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: scriptURL.path
            )
        }
        return scriptURL.path
    }

    func makeFile(relativePath: String, content: String) throws -> String {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }

    func makeExecutable(relativePath: String, content: String) throws -> String {
        let path = try makeFile(relativePath: relativePath, content: content)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: path
        )
        return path
    }

    func makeFakeLaunchctl() throws -> (path: String, logPath: String, agentsDir: String) {
        let logPath = rootURL.appendingPathComponent("fake-launchctl.log").path
        let agentsDir = rootURL.appendingPathComponent("LaunchAgents").path
        let script = """
            #!/bin/sh
            echo "$@" >> "$SCRIPTORIA_FAKE_LAUNCHCTL_LOG"
            exit 0
            """
        let path = try makeExecutable(relativePath: "bin/fake-launchctl.sh", content: script)
        return (path, logPath, agentsDir)
    }

    func makeFakeCodex() throws -> String {
        let script = #"""
            #!/usr/bin/env python3
            import json
            import os
            import sys

            mode = os.environ.get("SCRIPTORIA_FAKE_CODEX_MODE", "complete")
            thread_id = os.environ.get("SCRIPTORIA_FAKE_CODEX_THREAD_ID", "thread-test")
            turn_id = os.environ.get("SCRIPTORIA_FAKE_CODEX_TURN_ID", "turn-test")
            pid_file = os.environ.get("SCRIPTORIA_FAKE_CODEX_PID_FILE")

            if pid_file:
                try:
                    with open(pid_file, "w", encoding="utf-8") as f:
                        f.write(str(os.getpid()))
                except Exception:
                    pass

            def send(payload):
                sys.stdout.write(json.dumps(payload) + "\n")
                sys.stdout.flush()

            for raw in sys.stdin:
                raw = raw.strip()
                if not raw:
                    continue

                try:
                    request = json.loads(raw)
                except Exception:
                    continue

                method = request.get("method")
                req_id = request.get("id")

                if req_id is None:
                    continue

                if method == "initialize":
                    send({"jsonrpc": "2.0", "id": req_id, "result": {}})
                elif method == "thread/start":
                    send({"jsonrpc": "2.0", "id": req_id, "result": {"thread": {"id": thread_id}}})
                    send({"jsonrpc": "2.0", "method": "thread/started", "params": {"thread": {"id": thread_id}}})
                elif method == "turn/start":
                    send({"jsonrpc": "2.0", "id": req_id, "result": {"turn": {"id": turn_id}}})
                    send({"jsonrpc": "2.0", "method": "turn/started", "params": {"turn": {"id": turn_id}}})
                    if mode == "complete":
                        send({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {"itemId": "agent-1", "delta": "agent delta\n"}})
                        send({"jsonrpc": "2.0", "method": "item/commandExecution/outputDelta", "params": {"itemId": "cmd-1", "delta": "command delta\n"}})
                        send({"jsonrpc": "2.0", "method": "item/completed", "params": {"item": {"type": "agentMessage", "phase": "final_answer", "text": "final answer"}}})
                        send({"jsonrpc": "2.0", "method": "turn/completed", "params": {"turn": {"id": turn_id, "status": "completed"}}})
                    elif mode == "interrupt_on_start":
                        send({"jsonrpc": "2.0", "method": "turn/completed", "params": {"turn": {"id": turn_id, "status": "interrupted"}}})
                    elif mode == "exit_after_turn_start":
                        sys.exit(3)
                elif method == "turn/steer":
                    steer_text = ""
                    try:
                        steer_text = request["params"]["input"][0]["text"]
                    except Exception:
                        pass
                    send({"jsonrpc": "2.0", "id": req_id, "result": {}})
                    send({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {"itemId": "agent-1", "delta": f"steer:{steer_text}\n"}})
                    send({"jsonrpc": "2.0", "method": "item/completed", "params": {"item": {"type": "agentMessage", "phase": "final_answer", "text": "steer done"}}})
                    send({"jsonrpc": "2.0", "method": "turn/completed", "params": {"turn": {"id": turn_id, "status": "completed"}}})
                elif method == "turn/interrupt":
                    send({"jsonrpc": "2.0", "id": req_id, "result": {}})
                    send({"jsonrpc": "2.0", "method": "turn/completed", "params": {"turn": {"id": turn_id, "status": "interrupted"}}})
                else:
                    send({"jsonrpc": "2.0", "id": req_id, "result": {}})
            """#
        return try makeExecutable(relativePath: "bin/fake-codex", content: script)
    }
}

@discardableResult
func withEnvironment<T>(
    _ overrides: [String: String?],
    _ operation: () async throws -> T
) async rethrows -> T {
    var previous: [String: String?] = [:]
    for (key, value) in overrides {
        previous[key] = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    defer {
        for (key, value) in previous {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    return try await operation()
}

func waitForProcessToExit(_ pid: Int32, timeout: TimeInterval = 3.0) {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if kill(pid, 0) != 0 {
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

@discardableResult
func withTestWorkspace<T: Sendable>(
    prefix: String = "scriptoria-tests",
    _ operation: @Sendable (TestWorkspace) async throws -> T
) async throws -> T {
    await workspaceGate.acquire()

    do {
        let workspace = try TestWorkspace(prefix: prefix)
        defer { workspace.cleanup() }
        let result = try await withEnvironment(workspace.baseEnvironment) {
            try await operation(workspace)
        }
        await workspaceGate.release()
        return result
    } catch {
        await workspaceGate.release()
        throw error
    }
}

private actor WorkspaceGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

private let workspaceGate = WorkspaceGate()

final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ value: Element) {
        lock.withLock {
            storage.append(value)
        }
    }

    func values() -> [Element] {
        lock.withLock { storage }
    }
}

enum TimeoutError: Error {
    case timedOut
}

func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timedOut
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

func runCLI(
    arguments: [String],
    extraEnvironment: [String: String?] = [:],
    cwd: String? = nil,
    timeout: TimeInterval = 15
) throws -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try findScriptoriaExecutable())
    process.arguments = arguments
    process.currentDirectoryURL = cwd.map { URL(fileURLWithPath: $0) }

    var env = ProcessInfo.processInfo.environment
    for key in [
        "SCRIPTORIA_DEFAULT_DATA_DIR",
        "SCRIPTORIA_POINTER_FILE",
        "SCRIPTORIA_DATA_DIR",
        "SCRIPTORIA_LAUNCH_AGENTS_DIR",
        "SCRIPTORIA_LAUNCHCTL_PATH",
        "SCRIPTORIA_FAKE_LAUNCHCTL_LOG",
        "SCRIPTORIA_CODEX_EXECUTABLE",
        "SCRIPTORIA_FAKE_CODEX_MODE",
        "SCRIPTORIA_FAKE_CODEX_THREAD_ID",
        "SCRIPTORIA_FAKE_CODEX_TURN_ID",
        "SCRIPTORIA_FAKE_CODEX_PID_FILE"
    ] {
        if let value = getenv(key).map({ String(cString: $0) }) {
            env[key] = value
        } else {
            env.removeValue(forKey: key)
        }
    }
    for (key, value) in extraEnvironment {
        if let value {
            env[key] = value
        } else {
            env.removeValue(forKey: key)
        }
    }
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        timedOut = true
        process.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return CLIResult(
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus,
        timedOut: timedOut
    )
}

private func findScriptoriaExecutable() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let candidates = [
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/scriptoria").path,
        root.appendingPathComponent(".build/debug/scriptoria").path,
        URL(fileURLWithPath: Bundle.main.executablePath ?? "")
            .deletingLastPathComponent()
            .appendingPathComponent("scriptoria")
            .path
    ]

    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }

    throw NSError(
        domain: "ScriptoriaTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "scriptoria executable not found"]
    )
}
