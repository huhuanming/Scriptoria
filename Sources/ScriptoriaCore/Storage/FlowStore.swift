import Foundation

public final class FlowStore: @unchecked Sendable {
    private let db: DatabaseManager
    private var definitions: [FlowDefinitionRecord] = []
    private let lock = NSLock()

    public init(baseDirectory: String? = nil) {
        let dir = baseDirectory ?? Config.resolveDataDirectory()
        do {
            self.db = try DatabaseManager(directory: dir)
        } catch {
            let fallback = Config.defaultDataDirectory
            if dir != fallback {
                self.db = try! DatabaseManager(directory: fallback)
            } else {
                fatalError("Cannot open Scriptoria database at \(dir): \(error)")
            }
        }
    }

    public convenience init(config: Config) {
        self.init(baseDirectory: config.dataDirectory)
    }

    public static func fromConfig() -> FlowStore {
        FlowStore(config: Config.load())
    }

    public func load() async throws {
        let loaded = try db.fetchAllFlowDefinitions()
        lock.withLock { definitions = loaded }
    }

    public func allDefinitions() -> [FlowDefinitionRecord] {
        lock.withLock { definitions }
    }

    public func definitionSummaries() throws -> [FlowDefinitionStatusSummary] {
        try db.fetchFlowDefinitionSummaries()
    }

    public func upsertDefinition(
        flowPath: String,
        name: String? = nil,
        tags: [String] = []
    ) throws -> FlowDefinitionRecord {
        let record = try db.upsertFlowDefinition(flowPath: flowPath, name: name, tags: tags)
        lock.withLock {
            if let index = definitions.firstIndex(where: { $0.id == record.id }) {
                definitions[index] = record
            } else {
                definitions.append(record)
            }
            definitions.sort { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
        return record
    }

    public func fetchDefinition(id: UUID) throws -> FlowDefinitionRecord? {
        try db.fetchFlowDefinition(id: id)
    }

    public func fetchDefinition(canonicalFlowPath: String) throws -> FlowDefinitionRecord? {
        try db.fetchFlowDefinition(canonicalFlowPath: canonicalFlowPath)
    }

    public func markValidated(definitionID: UUID, at date: Date = Date()) throws {
        try db.markFlowDefinitionValidated(id: definitionID, at: date)
    }

    public func markCompiled(definitionID: UUID, at date: Date = Date()) throws {
        try db.markFlowDefinitionCompiled(id: definitionID, at: date)
    }

    public func markRan(definitionID: UUID, at date: Date = Date()) throws {
        try db.markFlowDefinitionRan(id: definitionID, at: date)
    }

    public func insertRun(_ run: FlowRunRecord) throws {
        try db.insertFlowRun(run)
    }

    public func updateRun(_ run: FlowRunRecord) throws {
        try db.updateFlowRun(run)
    }

    public func fetchRun(id: UUID) throws -> FlowRunRecord? {
        try db.fetchFlowRun(id: id)
    }

    public func fetchRuns(definitionID: UUID, limit: Int = 50) throws -> [FlowRunRecord] {
        try db.fetchFlowRuns(flowDefinitionID: definitionID, limit: limit)
    }

    public func fetchLatestRun(definitionID: UUID) throws -> FlowRunRecord? {
        try db.fetchLatestFlowRun(flowDefinitionID: definitionID)
    }

    public func insertStep(runID: UUID, event: FlowStepChangedEvent) throws {
        try db.insertFlowStep(runID: runID, event: event)
    }

    public func fetchSteps(runID: UUID) throws -> [FlowStepRecord] {
        try db.fetchFlowSteps(flowRunID: runID)
    }

    public func insertWarning(
        scope: FlowWarningScope,
        runID: UUID?,
        definitionID: UUID?,
        stateID: String?,
        code: String,
        message: String
    ) throws {
        _ = try db.insertFlowWarning(
            scope: scope,
            flowRunID: runID,
            flowDefinitionID: definitionID,
            stateID: stateID,
            code: code,
            message: message
        )
    }

    public func fetchWarnings(runID: UUID) throws -> [FlowWarningRecord] {
        try db.fetchFlowWarnings(flowRunID: runID)
    }

    public func fetchWarnings(definitionID: UUID) throws -> [FlowWarningRecord] {
        try db.fetchFlowWarnings(flowDefinitionID: definitionID)
    }

    public func insertCommandEvent(runID: UUID, event: FlowCommandQueueChangedEvent) throws {
        try db.insertFlowCommandEvent(runID: runID, event: event)
    }

    public func fetchCommandEvents(runID: UUID, limit: Int = 1000) throws -> [FlowCommandEventRecord] {
        try db.fetchFlowCommandEvents(flowRunID: runID, limit: limit)
    }

    public func cleanupCommandEvents(olderThanDays days: Int = 30) throws -> Int {
        try db.cleanupFlowCommandEvents(olderThanDays: days)
    }

    public func insertCompileArtifact(
        flowDefinitionID: UUID,
        sourceFlowPath: String,
        sourceFlowHash: String,
        outputPath: String,
        outputHash: String,
        fileSize: Int64
    ) throws {
        _ = try db.insertFlowCompileArtifact(
            flowDefinitionID: flowDefinitionID,
            sourceFlowPath: sourceFlowPath,
            sourceFlowHash: sourceFlowHash,
            outputPath: outputPath,
            outputHash: outputHash,
            fileSize: fileSize
        )
    }

    public func fetchCompileArtifacts(definitionID: UUID, limit: Int = 50) throws -> [FlowCompileArtifactRecord] {
        try db.fetchFlowCompileArtifacts(flowDefinitionID: definitionID, limit: limit)
    }

    public func pruneCompileArtifacts(
        maxPerFlow: Int = 20,
        maxAgeDays: Int = 30,
        maxTotalBytes: Int64 = 1_000_000_000
    ) throws -> Int {
        try db.pruneFlowCompileArtifacts(
            maxPerFlow: maxPerFlow,
            maxAgeDays: maxAgeDays,
            maxTotalBytes: maxTotalBytes
        )
    }

    public func isSchemaReady() throws -> Bool {
        try db.isFlowSchemaReady()
    }
}
