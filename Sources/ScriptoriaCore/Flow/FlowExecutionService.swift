import CryptoKit
import Foundation

public enum FlowWorkbenchMode: String, Sendable {
    case full
    case diagnosticsOnly
}

public struct FlowValidateResult: Sendable {
    public var flowPath: String
    public var definitionID: UUID?
    public var definition: FlowYAMLDefinition
}

public struct FlowCompileResult: Sendable {
    public var flowPath: String
    public var definitionID: UUID?
    public var ir: FlowIR
    public var canonicalJSON: String
    public var outputPath: String
    public var cleanedArtifactsCount: Int
}

public struct FlowRunExecutionResult: Sendable {
    public var definitionID: UUID
    public var runID: UUID
    public var result: FlowRunResult
}

private final class LockedFlowRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var record: FlowRunRecord

    init(initial: FlowRunRecord) {
        self.record = initial
    }

    func snapshot() -> FlowRunRecord {
        lock.withLock { record }
    }

    func update(_ mutation: (inout FlowRunRecord) -> Void) -> FlowRunRecord {
        lock.withLock {
            mutation(&record)
            return record
        }
    }
}

public final class FlowExecutionService: @unchecked Sendable {
    private let flowStore: FlowStore

    public init(baseDirectory: String? = nil) {
        self.flowStore = FlowStore(baseDirectory: baseDirectory)
        runStartupMaintenance()
    }

    public init(flowStore: FlowStore) {
        self.flowStore = flowStore
        runStartupMaintenance()
    }

    public func workbenchMode() -> FlowWorkbenchMode {
        do {
            return try flowStore.isSchemaReady() ? .full : .diagnosticsOnly
        } catch {
            return .diagnosticsOnly
        }
    }

    public func loadDefinitions() async throws -> [FlowDefinitionRecord] {
        try await flowStore.load()
        return flowStore.allDefinitions()
    }

    public func listDefinitionSummaries() throws -> [FlowDefinitionStatusSummary] {
        try flowStore.definitionSummaries()
    }

    @discardableResult
    public func importDefinition(
        flowPath: String,
        name: String? = nil,
        tags: [String] = []
    ) throws -> FlowDefinitionRecord {
        try flowStore.upsertDefinition(flowPath: flowPath, name: name, tags: tags)
    }

    public func validate(
        flowPath: String,
        noFSCheck: Bool = false,
        registerDefinition: Bool = true
    ) throws -> FlowValidateResult {
        let definition = try FlowValidator.validateFile(
            atPath: flowPath,
            options: .init(checkFileSystem: !noFSCheck)
        )

        var definitionID: UUID?
        if registerDefinition {
            let record = try flowStore.upsertDefinition(flowPath: flowPath)
            definitionID = record.id
            try flowStore.markValidated(definitionID: record.id)
        }

        return FlowValidateResult(
            flowPath: flowPath,
            definitionID: definitionID,
            definition: definition
        )
    }

    public func compile(
        flowPath: String,
        outputPath: String,
        noFSCheck: Bool = false,
        registerDefinition: Bool = true
    ) throws -> FlowCompileResult {
        let ir = try FlowCompiler.compileFile(
            atPath: flowPath,
            options: .init(checkFileSystem: !noFSCheck)
        )
        let canonicalJSON = try FlowCompiler.renderCanonicalJSON(ir: ir)
        let absoluteOutputPath = FlowPathResolver.absolutePath(from: outputPath)
        let outputURL = URL(fileURLWithPath: absoluteOutputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try canonicalJSON.write(to: outputURL, atomically: true, encoding: .utf8)

        var definitionID: UUID?
        var cleanedArtifactsCount = 0
        if registerDefinition {
            let definition = try flowStore.upsertDefinition(flowPath: flowPath)
            definitionID = definition.id
            try flowStore.markCompiled(definitionID: definition.id)

            let sourceData = (try? Data(contentsOf: URL(fileURLWithPath: ir.sourcePath))) ?? Data()
            let artifactData = Data(canonicalJSON.utf8)
            try flowStore.insertCompileArtifact(
                flowDefinitionID: definition.id,
                sourceFlowPath: ir.sourcePath,
                sourceFlowHash: Self.sha256Hex(sourceData),
                outputPath: absoluteOutputPath,
                outputHash: Self.sha256Hex(artifactData),
                fileSize: Int64(artifactData.count)
            )

            do {
                cleanedArtifactsCount = try flowStore.pruneCompileArtifacts()
            } catch {
                try? flowStore.insertWarning(
                    scope: .system,
                    runID: nil,
                    definitionID: definition.id,
                    stateID: nil,
                    code: "flow.compile.cleanup_failed",
                    message: "Compile artifact cleanup failed: \(error.localizedDescription)"
                )
            }
        }

        return FlowCompileResult(
            flowPath: flowPath,
            definitionID: definitionID,
            ir: ir,
            canonicalJSON: canonicalJSON,
            outputPath: absoluteOutputPath,
            cleanedArtifactsCount: cleanedArtifactsCount
        )
    }

    public func runLive(
        flowPath: String,
        options: FlowRunOptions = .init(),
        commandInput: AsyncStream<String>? = nil,
        logSink: (@Sendable (String) -> Void)? = nil,
        eventSink: FlowRunEventSink? = nil
    ) async throws -> FlowRunExecutionResult {
        try await run(
            flowPath: flowPath,
            mode: .live,
            options: options,
            commandInput: commandInput,
            logSink: logSink,
            eventSink: eventSink
        )
    }

    public func runDry(
        flowPath: String,
        fixturePath: String,
        options: FlowRunOptions = .init(),
        logSink: (@Sendable (String) -> Void)? = nil,
        eventSink: FlowRunEventSink? = nil
    ) async throws -> FlowRunExecutionResult {
        let fixture: FlowDryRunFixture
        do {
            fixture = try FlowDryRunFixture.load(fromPath: fixturePath)
        } catch let error as FlowError {
            throw error
        } catch {
            throw FlowError(
                code: "flow.validate.schema_error",
                message: error.localizedDescription,
                phase: .runtimeDryRun
            )
        }

        return try await run(
            flowPath: flowPath,
            mode: .dryRun(fixture),
            options: options,
            commandInput: nil,
            logSink: logSink,
            eventSink: eventSink
        )
    }

    public func fetchRunHistory(definitionID: UUID, limit: Int = 50) throws -> [FlowRunRecord] {
        try flowStore.fetchRuns(definitionID: definitionID, limit: limit)
    }

    public func fetchSteps(runID: UUID) throws -> [FlowStepRecord] {
        try flowStore.fetchSteps(runID: runID)
    }

    public func fetchWarnings(runID: UUID) throws -> [FlowWarningRecord] {
        try flowStore.fetchWarnings(runID: runID)
    }

    public func fetchWarnings(definitionID: UUID) throws -> [FlowWarningRecord] {
        try flowStore.fetchWarnings(definitionID: definitionID)
    }

    public func fetchCommandEvents(runID: UUID, limit: Int = 1000) throws -> [FlowCommandEventRecord] {
        try flowStore.fetchCommandEvents(runID: runID, limit: limit)
    }

    private func run(
        flowPath: String,
        mode: FlowRunMode,
        options: FlowRunOptions,
        commandInput: AsyncStream<String>?,
        logSink: (@Sendable (String) -> Void)?,
        eventSink: FlowRunEventSink?
    ) async throws -> FlowRunExecutionResult {
        let ir: FlowIR
        do {
            ir = try FlowCompiler.compileFile(atPath: flowPath)
        } catch let error as FlowError {
            throw FlowErrors.runtimePreflight(from: error)
        } catch {
            throw FlowError(
                code: "flow.validate.schema_error",
                message: error.localizedDescription,
                phase: .runtimePreflight
            )
        }

        let definition = try flowStore.upsertDefinition(flowPath: flowPath)
        let runUUID = UUID()
        let runID = runUUID.uuidString.lowercased()
        let capIgnored = options.maxAgentRoundsCap.map { $0 > ir.defaults.maxAgentRounds } ?? false

        let runMode: FlowRunRecordMode
        switch mode {
        case .live:
            runMode = .live
        case .dryRun:
            runMode = .dry
        }

        let runRecord = FlowRunRecord(
            id: runUUID,
            flowDefinitionID: definition.id,
            flowPathSnapshot: ir.sourcePath,
            mode: runMode,
            startedAt: Date(),
            finishedAt: nil,
            status: .running,
            endedAtState: nil,
            steps: 0,
            errorCode: nil,
            errorMessage: nil,
            provider: nil,
            model: nil,
            executablePath: nil,
            executableSource: nil,
            commandsQueued: options.commands.count,
            commandsConsumed: 0,
            commandEventsTruncated: false,
            commandEventsTruncatedCount: 0
        )
        try flowStore.insertRun(runRecord)
        let runState = LockedFlowRunState(initial: runRecord)

        if capIgnored {
            let warningCode = "flow.cli.max_agent_rounds_cap_ignored"
            let warningMessage = "--max-agent-rounds (\(options.maxAgentRoundsCap ?? 0)) does not relax configured max_agent_rounds (\(ir.defaults.maxAgentRounds)); using configured cap."
            try? flowStore.insertWarning(
                scope: .run,
                runID: runUUID,
                definitionID: definition.id,
                stateID: nil,
                code: warningCode,
                message: warningMessage
            )
            let warningEvent = FlowRunEvent.warningRaised(
                FlowWarningRaisedEvent(
                    runID: runID,
                    code: warningCode,
                    message: warningMessage,
                    scope: .run,
                    flowDefinitionID: definition.id.uuidString.lowercased(),
                    stateID: nil
                )
            )
            eventSink?(warningEvent)
        }

        let persistenceSink: FlowRunEventSink = { [flowStore] event in
            switch event {
            case .runStarted(let started):
                let updated = runState.update { record in
                    record.provider = started.provider
                    record.model = started.model
                    record.executablePath = started.executablePath
                    record.executableSource = started.executableSource
                }
                try? flowStore.updateRun(updated)

            case .stepChanged(let step):
                try? flowStore.insertStep(runID: runUUID, event: step)

            case .warningRaised(let warning):
                let linkedRunID: UUID? = (warning.scope == .run || warning.scope == .state) ? runUUID : nil
                let linkedDefinitionID: UUID? = definition.id
                try? flowStore.insertWarning(
                    scope: warning.scope,
                    runID: linkedRunID,
                    definitionID: linkedDefinitionID,
                    stateID: warning.stateID,
                    code: warning.code,
                    message: warning.message
                )

            case .commandQueueChanged(let commandEvent):
                try? flowStore.insertCommandEvent(runID: runUUID, event: commandEvent)

            case .runCompleted(let completed):
                var updated = runState.update { record in
                    record.status = completed.status == .success ? .success : .failure
                    record.finishedAt = completed.finishedAt
                    record.endedAtState = completed.endedAtStateID
                    record.steps = completed.steps
                    if record.status == .success {
                        record.errorCode = nil
                        record.errorMessage = nil
                    }
                }
                if let refreshed = try? flowStore.fetchRun(id: runUUID) {
                    updated = runState.update { record in
                        record.commandsQueued = refreshed.commandsQueued
                        record.commandsConsumed = refreshed.commandsConsumed
                        record.commandEventsTruncated = refreshed.commandEventsTruncated
                        record.commandEventsTruncatedCount = refreshed.commandEventsTruncatedCount
                    }
                }
                try? flowStore.updateRun(updated)
                try? flowStore.markRan(definitionID: definition.id, at: completed.finishedAt)
            }
            eventSink?(event)
        }

        var effectiveOptions = options
        effectiveOptions.runID = runID
        effectiveOptions.flowDefinitionID = definition.id.uuidString.lowercased()

        do {
            var result = try await FlowEngine().run(
                ir: ir,
                mode: mode,
                options: effectiveOptions,
                commandInput: commandInput,
                logSink: logSink,
                eventSink: persistenceSink
            )
            if capIgnored {
                result.warnings.insert(
                    FlowWarning(
                        code: "flow.cli.max_agent_rounds_cap_ignored",
                        message: "--max-agent-rounds (\(options.maxAgentRoundsCap ?? 0)) does not relax configured max_agent_rounds (\(ir.defaults.maxAgentRounds)); using configured cap.",
                        scope: .run,
                        stateID: nil
                    ),
                    at: 0
                )
            }
            do {
                _ = try flowStore.cleanupCommandEvents()
            } catch {
                try? flowStore.insertWarning(
                    scope: .system,
                    runID: nil,
                    definitionID: definition.id,
                    stateID: nil,
                    code: "flow.command.cleanup_failed",
                    message: "Flow command event cleanup failed: \(error.localizedDescription)"
                )
            }
            return FlowRunExecutionResult(definitionID: definition.id, runID: runUUID, result: result)
        } catch let error as FlowError {
            let failed = runState.update { record in
                record.status = .failure
                record.finishedAt = Date()
                record.errorCode = error.code
                record.errorMessage = error.message
            }
            try? flowStore.updateRun(failed)
            throw error
        } catch {
            let failed = runState.update { record in
                record.status = .failure
                record.finishedAt = Date()
                record.errorCode = "flow.validate.schema_error"
                record.errorMessage = error.localizedDescription
            }
            try? flowStore.updateRun(failed)
            throw error
        }
    }

    private func runStartupMaintenance() {
        Task.detached(priority: .utility) { [flowStore] in
            do {
                _ = try flowStore.cleanupCommandEvents()
            } catch {
                try? flowStore.insertWarning(
                    scope: .system,
                    runID: nil,
                    definitionID: nil,
                    stateID: nil,
                    code: "flow.command.cleanup_failed",
                    message: "Flow command event cleanup failed: \(error.localizedDescription)"
                )
            }

            do {
                _ = try flowStore.pruneCompileArtifacts()
            } catch {
                try? flowStore.insertWarning(
                    scope: .system,
                    runID: nil,
                    definitionID: nil,
                    stateID: nil,
                    code: "flow.compile.cleanup_failed",
                    message: "Flow compile artifact cleanup failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
