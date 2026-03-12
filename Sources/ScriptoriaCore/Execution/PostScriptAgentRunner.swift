import Foundation

public enum AgentStreamEventKind: Sendable {
    case info
    case agentMessage
    case commandOutput
    case error
}

public struct AgentStreamEvent: Sendable {
    public let kind: AgentStreamEventKind
    public let text: String

    public init(kind: AgentStreamEventKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct AgentExecutionResult: Sendable {
    public let threadId: String
    public let turnId: String
    public let model: String
    public let startedAt: Date
    public let finishedAt: Date
    public let status: AgentRunStatus
    public let finalMessage: String
    public let output: String
}

public struct PostScriptAgentLaunchOptions: Sendable {
    public var workingDirectory: String
    public var model: String
    public var userPrompt: String
    public var developerInstructions: String
    public var codexExecutable: String
    public var approvalPolicy: String
    public var sandbox: String

    public init(
        workingDirectory: String,
        model: String,
        userPrompt: String,
        developerInstructions: String,
        codexExecutable: String = "codex",
        approvalPolicy: String = "never",
        sandbox: String = "danger-full-access"
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.userPrompt = userPrompt
        self.developerInstructions = developerInstructions
        self.codexExecutable = codexExecutable
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
    }
}

public actor PostScriptAgentSession {
    private let client: CodexAppServerClient
    private let model: String
    private let startedAt: Date
    private let onEvent: (@Sendable (AgentStreamEvent) -> Void)?

    public private(set) var threadId: String
    public private(set) var turnId: String = ""

    private var outputBuffer = ""
    private var finalMessage = ""
    private var completionResult: AgentExecutionResult?
    private var completionContinuation: CheckedContinuation<AgentExecutionResult, Error>?
    private var pendingTurnCompletion: (turnId: String, status: String)?

    init(
        client: CodexAppServerClient,
        threadId: String,
        model: String,
        startedAt: Date = Date(),
        onEvent: (@Sendable (AgentStreamEvent) -> Void)?
    ) {
        self.client = client
        self.threadId = threadId
        self.model = model
        self.startedAt = startedAt
        self.onEvent = onEvent
    }

    func activate(turnId: String) {
        self.turnId = turnId
        consumePendingCompletionIfNeeded()
    }

    func handle(event: CodexAppServerEvent) async {
        switch event {
        case .threadStarted(let threadId):
            self.threadId = threadId

        case .turnStarted(let turnId):
            if self.turnId.isEmpty {
                self.turnId = turnId
                consumePendingCompletionIfNeeded()
            }

        case .agentMessageDelta(_, let delta):
            outputBuffer += delta
            onEvent?(AgentStreamEvent(kind: .agentMessage, text: delta))

        case .commandOutputDelta(_, let delta):
            outputBuffer += delta
            onEvent?(AgentStreamEvent(kind: .commandOutput, text: delta))

        case .agentMessageCompleted(let phase, let text):
            if phase == "final_answer" {
                finalMessage = text
                if !text.isEmpty, !outputBuffer.contains(text) {
                    outputBuffer += text
                }
            }

        case .turnCompleted(let turnId, let status):
            if self.turnId.isEmpty {
                pendingTurnCompletion = (turnId: turnId, status: status)
                return
            }
            guard turnId == self.turnId else { return }
            finish(status: mapStatus(status))

        case .processTerminated(let exitCode):
            onEvent?(AgentStreamEvent(kind: .error, text: "codex app-server exited with code \(exitCode)\n"))
            finish(status: .failed)

        case .diagnostic(let line):
            onEvent?(AgentStreamEvent(kind: .info, text: line + "\n"))
        }
    }

    public func waitForCompletion() async throws -> AgentExecutionResult {
        if let completionResult { return completionResult }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completionContinuation = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPendingWait()
            }
        }
    }

    public func steer(_ input: String) async throws {
        guard !turnId.isEmpty else { return }
        try await client.steer(threadId: threadId, turnId: turnId, input: input)
        onEvent?(AgentStreamEvent(kind: .info, text: "[steer] \(input)\n"))
    }

    public func interrupt() async throws {
        guard !turnId.isEmpty else { return }
        try await client.interrupt(threadId: threadId, turnId: turnId)
        onEvent?(AgentStreamEvent(kind: .info, text: "[interrupt] requested\n"))
    }

    public func close() async {
        await client.shutdown()
        if completionResult == nil {
            finish(status: .failed)
        }
    }

    private func finish(status: AgentRunStatus) {
        guard completionResult == nil else { return }
        let result = AgentExecutionResult(
            threadId: threadId,
            turnId: turnId,
            model: model,
            startedAt: startedAt,
            finishedAt: Date(),
            status: status,
            finalMessage: finalMessage,
            output: outputBuffer
        )
        completionResult = result
        completionContinuation?.resume(returning: result)
        completionContinuation = nil
        Task {
            await client.shutdown()
        }
    }

    private func consumePendingCompletionIfNeeded() {
        guard let pendingTurnCompletion else { return }
        guard !turnId.isEmpty, pendingTurnCompletion.turnId == turnId else { return }
        self.pendingTurnCompletion = nil
        finish(status: mapStatus(pendingTurnCompletion.status))
    }

    private func cancelPendingWait() {
        guard completionResult == nil else { return }
        completionContinuation?.resume(throwing: CancellationError())
        completionContinuation = nil
    }

    private func mapStatus(_ status: String) -> AgentRunStatus {
        switch status {
        case "completed":
            return .completed
        case "interrupted":
            return .interrupted
        default:
            return .failed
        }
    }
}

public enum PostScriptAgentRunner {
    public static func launch(
        options: PostScriptAgentLaunchOptions,
        onEvent: (@Sendable (AgentStreamEvent) -> Void)? = nil
    ) async throws -> PostScriptAgentSession {
        let envExecutable = ProcessInfo.processInfo.environment["SCRIPTORIA_CODEX_EXECUTABLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = (envExecutable?.isEmpty == false) ? envExecutable! : options.codexExecutable
        let client = CodexAppServerClient(cwd: options.workingDirectory, executable: executable)
        do {
            try await client.connect()

            let threadId = try await client.startThread(
                model: options.model,
                developerInstructions: options.developerInstructions,
                approvalPolicy: options.approvalPolicy,
                sandbox: options.sandbox
            )

            let session = PostScriptAgentSession(
                client: client,
                threadId: threadId,
                model: options.model,
                onEvent: onEvent
            )

            await client.setEventHandler { event in
                Task {
                    await session.handle(event: event)
                }
            }

            let turnId = try await client.startTurn(threadId: threadId, input: options.userPrompt)
            await session.activate(turnId: turnId)
            return session
        } catch {
            await client.shutdown()
            throw error
        }
    }

    public static func buildDeveloperInstructions(
        skillContent: String?,
        workspaceMemory: String?
    ) -> String {
        var sections: [String] = []
        sections.append("""
            You are Scriptoria's post-script execution agent.
            Execute the user's task autonomously, stream concise progress, and end with a clear final answer.
            """)

        if let skillContent, !skillContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("## Injected Skill\n\(skillContent)")
        }

        if let workspaceMemory, !workspaceMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("## Workspace Memory\n\(workspaceMemory)")
        } else {
            sections.append("## Workspace Memory\n(no workspace memory yet)")
        }

        return sections.joined(separator: "\n\n")
    }

    public static func buildInitialPrompt(
        taskName: String,
        script: Script,
        scriptRun: ScriptRun
    ) -> String {
        let status = scriptRun.status.rawValue
        let exitCode = scriptRun.exitCode.map(String.init) ?? "?"
        let stdout = scriptRun.output.isEmpty ? "(empty)" : scriptRun.output
        let stderr = scriptRun.errorOutput.isEmpty ? "(empty)" : scriptRun.errorOutput

        return """
            Task Name: \(taskName)
            Script: \(script.title)
            Script Path: \(script.path)
            Script Run Status: \(status)
            Script Exit Code: \(exitCode)

            Script STDOUT:
            \(stdout)

            Script STDERR:
            \(stderr)

            Please execute this task end-to-end using the injected skill and memory context.
            """
    }
}
