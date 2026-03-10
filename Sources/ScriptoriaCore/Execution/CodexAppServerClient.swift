import Foundation

public enum CodexAppServerEvent: Sendable {
    case threadStarted(threadId: String)
    case turnStarted(turnId: String)
    case turnCompleted(turnId: String, status: String)
    case processTerminated(exitCode: Int32)
    case agentMessageDelta(itemId: String, delta: String)
    case commandOutputDelta(itemId: String, delta: String)
    case agentMessageCompleted(phase: String?, text: String)
    case diagnostic(String)
}

public enum CodexAppServerClientError: LocalizedError {
    case processNotRunning
    case invalidResponse(String)
    case responseError(String)
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "Codex app-server process is not running."
        case .invalidResponse(let line):
            return "Invalid response from Codex app-server: \(line)"
        case .responseError(let message):
            return "Codex app-server returned an error: \(message)"
        case .missingField(let field):
            return "Codex app-server response missing field: \(field)"
        }
    }
}

/// Minimal JSON-RPC client for `codex app-server --listen stdio://`.
public actor CodexAppServerClient {
    public typealias EventHandler = @Sendable (CodexAppServerEvent) -> Void

    private let cwd: String
    private let executable: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestId = 1
    private var pendingResponses: [String: CheckedContinuation<Data, Error>] = [:]
    private var eventHandler: EventHandler?
    private var isClosed = false
    private let debugEnabled: Bool

    public init(cwd: String, executable: String = "codex") {
        self.cwd = cwd
        self.executable = executable
        let flag = ProcessInfo.processInfo.environment["SCRIPTORIA_CODEX_DEBUG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.debugEnabled = flag == "1" || flag == "true" || flag == "yes"
    }

    public func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    public func connect() async throws {
        guard process == nil else { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "app-server", "--listen", "stdio://"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleTermination(exitCode: proc.terminationStatus) }
        }

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.isClosed = false

        startReadTasks(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        _ = try await sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "scriptoria",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        )
        try sendNotification(method: "initialized", params: nil)
    }

    public func startThread(
        model: String?,
        developerInstructions: String?,
        approvalPolicy: String = "never",
        sandbox: String = "danger-full-access"
    ) async throws -> String {
        var params: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": approvalPolicy,
            "sandbox": sandbox
        ]
        if let model, !model.isEmpty {
            params["model"] = model
        }
        if let developerInstructions, !developerInstructions.isEmpty {
            params["developerInstructions"] = developerInstructions
        }

        let result = try await sendRequest(method: "thread/start", params: params)
        guard let thread = result["thread"] as? [String: Any],
              let threadId = thread["id"] as? String else {
            throw CodexAppServerClientError.missingField("thread.id")
        }
        return threadId
    }

    public func startTurn(threadId: String, input: String) async throws -> String {
        let result = try await sendRequest(
            method: "turn/start",
            params: [
                "threadId": threadId,
                "input": [
                    [
                        "type": "text",
                        "text": input
                    ]
                ]
            ]
        )
        guard let turn = result["turn"] as? [String: Any],
              let turnId = turn["id"] as? String else {
            throw CodexAppServerClientError.missingField("turn.id")
        }
        return turnId
    }

    public func steer(threadId: String, turnId: String, input: String) async throws {
        _ = try await sendRequest(
            method: "turn/steer",
            params: [
                "threadId": threadId,
                "expectedTurnId": turnId,
                "input": [
                    [
                        "type": "text",
                        "text": input
                    ]
                ]
            ]
        )
    }

    public func interrupt(threadId: String, turnId: String) async throws {
        _ = try await sendRequest(
            method: "turn/interrupt",
            params: [
                "threadId": threadId,
                "turnId": turnId
            ]
        )
    }

    public func shutdown() async {
        guard !isClosed else { return }
        isClosed = true

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: CodexAppServerClientError.processNotRunning)
        }
        pendingResponses.removeAll()
    }

    // MARK: - Private

    private func startReadTasks(stdoutPipe: Pipe, stderrPipe: Pipe) {
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task {
                await self.handleStdoutChunk(data)
            }
        }

        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task {
                await self.handleStderrChunk(data)
            }
        }
    }

    private func handleStdoutChunk(_ data: Data) async {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            var lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            stdoutBuffer.removeSubrange(...newlineIndex)
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            guard let line = String(data: lineData, encoding: .utf8) else {
                emit(.diagnostic("codex app-server stdout line decode error"))
                continue
            }
            await handleStdoutLine(line)
        }
    }

    private func handleStderrChunk(_ data: Data) async {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        while let newlineIndex = stderrBuffer.firstIndex(of: 0x0A) {
            var lineData = stderrBuffer.prefix(upTo: newlineIndex)
            stderrBuffer.removeSubrange(...newlineIndex)
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            guard let line = String(data: lineData, encoding: .utf8) else {
                emit(.diagnostic("codex app-server stderr line decode error"))
                continue
            }
            emit(.diagnostic("codex app-server: \(line)"))
        }
    }

    private func handleTermination(exitCode: Int32) {
        if isClosed { return }
        isClosed = true

        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: CodexAppServerClientError.responseError("Process exited with code \(exitCode)"))
        }
        pendingResponses.removeAll()

        emit(.processTerminated(exitCode: exitCode))
        emit(.diagnostic("codex app-server exited with code \(exitCode)"))
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard process != nil, !isClosed else { throw CodexAppServerClientError.processNotRunning }

        let id = String(nextRequestId)
        nextRequestId += 1
        debugLog("sendRequest id=\(id) method=\(method)")

        try writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])

        let resultData: Data = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
        }
        debugLog("gotResponse id=\(id) bytes=\(resultData.count)")
        guard let object = try JSONSerialization.jsonObject(with: resultData, options: []) as? [String: Any] else {
            throw CodexAppServerClientError.invalidResponse(String(data: resultData, encoding: .utf8) ?? "<binary>")
        }
        return object
    }

    private func sendNotification(method: String, params: [String: Any]?) throws {
        guard process != nil, !isClosed else { throw CodexAppServerClientError.processNotRunning }

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        try writeJSON(payload)
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard let stdinPipe else { throw CodexAppServerClientError.processNotRunning }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func handleStdoutLine(_ line: String) async {
        guard !line.isEmpty else { return }
        debugLog("stdout \(line)")
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            emit(.diagnostic("unparsed line: \(line)"))
            return
        }

        if let id = stringValue(dict["id"]) {
            guard let continuation = pendingResponses.removeValue(forKey: id) else {
                debugLog("response without continuation id=\(id)")
                return
            }
            if let errorDict = dict["error"] as? [String: Any] {
                let message = errorDict["message"] as? String ?? "Unknown error"
                continuation.resume(throwing: CodexAppServerClientError.responseError(message))
                return
            }
            if let result = dict["result"] as? [String: Any] {
                let resultData = (try? JSONSerialization.data(withJSONObject: result, options: [])) ?? Data("{}".utf8)
                continuation.resume(returning: resultData)
                return
            }
            continuation.resume(returning: Data("{}".utf8))
            return
        }

        guard let method = dict["method"] as? String else { return }
        let params = dict["params"] as? [String: Any] ?? [:]
        await handleNotification(method: method, params: params)
    }

    private func handleNotification(method: String, params: [String: Any]) async {
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any],
               let threadId = thread["id"] as? String {
                emit(.threadStarted(threadId: threadId))
            }

        case "turn/started":
            if let turn = params["turn"] as? [String: Any],
               let turnId = turn["id"] as? String {
                emit(.turnStarted(turnId: turnId))
            }

        case "turn/completed":
            if let turn = params["turn"] as? [String: Any],
               let turnId = turn["id"] as? String,
               let status = turn["status"] as? String {
                emit(.turnCompleted(turnId: turnId, status: status))
            }

        case "item/agentMessage/delta":
            if let itemId = params["itemId"] as? String,
               let delta = params["delta"] as? String {
                emit(.agentMessageDelta(itemId: itemId, delta: delta))
            }

        case "item/commandExecution/outputDelta":
            if let itemId = params["itemId"] as? String,
               let delta = params["delta"] as? String {
                emit(.commandOutputDelta(itemId: itemId, delta: delta))
            }

        case "item/completed":
            if let item = params["item"] as? [String: Any],
               let type = item["type"] as? String,
               type == "agentMessage" {
                let phase = item["phase"] as? String
                let text = item["text"] as? String ?? ""
                emit(.agentMessageCompleted(phase: phase, text: text))
            }

        default:
            break
        }
    }

    private func emit(_ event: CodexAppServerEvent) {
        eventHandler?(event)
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func debugLog(_ message: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("[codex-client] \(message)\n".utf8))
    }
}
