import CryptoKit
import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Flow Migration Helpers

    static func applyFlowSchemaMigration(db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS flow_definitions (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL,
              displayFlowPath TEXT NOT NULL,
              canonicalFlowPath TEXT NOT NULL,
              workspacePath TEXT NOT NULL,
              tagsJSON TEXT NOT NULL DEFAULT '[]',
              isPinned INTEGER NOT NULL DEFAULT 0,
              createdAt DATETIME NOT NULL,
              updatedAt DATETIME NOT NULL,
              lastValidatedAt DATETIME,
              lastCompiledAt DATETIME,
              lastRunAt DATETIME
            )
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS flow_runs (
              id TEXT PRIMARY KEY NOT NULL,
              flowDefinitionId TEXT NOT NULL REFERENCES flow_definitions(id) ON DELETE CASCADE,
              flowPathSnapshot TEXT NOT NULL,
              mode TEXT NOT NULL,
              startedAt DATETIME NOT NULL,
              finishedAt DATETIME,
              status TEXT NOT NULL,
              endedAtState TEXT,
              steps INTEGER NOT NULL DEFAULT 0,
              errorCode TEXT,
              errorMessage TEXT,
              provider TEXT,
              model TEXT,
              executablePath TEXT,
              executableSource TEXT,
              commandsQueued INTEGER NOT NULL DEFAULT 0,
              commandsConsumed INTEGER NOT NULL DEFAULT 0,
              commandEventsTruncated INTEGER NOT NULL DEFAULT 0,
              commandEventsTruncatedCount INTEGER NOT NULL DEFAULT 0
            )
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS flow_steps (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              flowRunId TEXT NOT NULL REFERENCES flow_runs(id) ON DELETE CASCADE,
              seq INTEGER NOT NULL,
              phase TEXT NOT NULL,
              stateId TEXT NOT NULL,
              stateType TEXT NOT NULL,
              attempt INTEGER NOT NULL,
              decision TEXT,
              transition TEXT,
              duration REAL,
              counterJSON TEXT,
              stateOutputJSON TEXT,
              contextDeltaJSON TEXT,
              stateLastJSON TEXT,
              errorCode TEXT,
              errorMessage TEXT,
              createdAt DATETIME NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS flow_warnings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              scope TEXT NOT NULL,
              flowRunId TEXT REFERENCES flow_runs(id) ON DELETE CASCADE,
              flowDefinitionId TEXT REFERENCES flow_definitions(id) ON DELETE CASCADE,
              stateId TEXT,
              code TEXT NOT NULL,
              message TEXT NOT NULL,
              createdAt DATETIME NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS flow_command_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              flowRunId TEXT NOT NULL REFERENCES flow_runs(id) ON DELETE CASCADE,
              seq INTEGER NOT NULL,
              action TEXT NOT NULL,
              commandPreview TEXT NOT NULL,
              commandHash TEXT NOT NULL,
              queueDepth INTEGER NOT NULL,
              stateId TEXT,
              turnId TEXT,
              reason TEXT,
              createdAt DATETIME NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS flow_compile_artifacts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              flowDefinitionId TEXT NOT NULL REFERENCES flow_definitions(id) ON DELETE CASCADE,
              sourceFlowPath TEXT NOT NULL,
              sourceFlowHash TEXT NOT NULL,
              outputPath TEXT NOT NULL,
              outputHash TEXT NOT NULL,
              fileSize INTEGER NOT NULL,
              createdAt DATETIME NOT NULL
            )
            """)

        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_flow_definitions_canonical ON flow_definitions(canonicalFlowPath)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_definitions_updatedAt_desc ON flow_definitions(updatedAt DESC)")

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_runs_definition_started_desc ON flow_runs(flowDefinitionId, startedAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_runs_status_started_desc ON flow_runs(status, startedAt DESC)")

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_steps_run_seq ON flow_steps(flowRunId, seq ASC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_steps_state_created_desc ON flow_steps(stateId, createdAt DESC)")

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_command_events_run_seq ON flow_command_events(flowRunId, seq ASC)")

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_compile_artifacts_definition_created_desc ON flow_compile_artifacts(flowDefinitionId, createdAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_compile_artifacts_created_desc ON flow_compile_artifacts(createdAt DESC)")

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_warnings_scope_created_desc ON flow_warnings(scope, createdAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_warnings_run_state_created_desc ON flow_warnings(flowRunId, stateId, createdAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_flow_warnings_definition_created_desc ON flow_warnings(flowDefinitionId, createdAt DESC)")
    }

    static func applyFlowBackfillMigration(db: Database) throws {
        guard try tableExists(db: db, name: "flow_runs"),
              try tableExists(db: db, name: "flow_definitions"),
              try columnExists(db: db, table: "flow_runs", column: "flowPathSnapshot")
        else {
            return
        }

        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, flowPathSnapshot, flowDefinitionId FROM flow_runs ORDER BY startedAt ASC"
        )
        for row in rows {
            let runID: String = row["id"]
            let linkedDefinitionID: String? = row["flowDefinitionId"]
            if let linkedDefinitionID, !linkedDefinitionID.isEmpty {
                continue
            }

            let flowPathSnapshot: String = row["flowPathSnapshot"]
            guard let resolved = FlowDefinitionPathResolver.tryResolve(rawPath: flowPathSnapshot) else {
                try db.execute(
                    sql: """
                        INSERT INTO flow_warnings (scope, flowRunId, flowDefinitionId, stateId, code, message, createdAt)
                        VALUES (?, NULL, NULL, NULL, ?, ?, ?)
                        """,
                    arguments: [
                        FlowWarningScope.system.rawValue,
                        "flow.migration.backfill_path_unresolved",
                        "Unable to resolve flow path during migration: \(flowPathSnapshot)",
                        Date()
                    ]
                )
                continue
            }

            let definitionID = try upsertDefinitionForBackfill(
                db: db,
                resolvedPath: resolved
            )
            try db.execute(
                sql: "UPDATE flow_runs SET flowDefinitionId = ? WHERE id = ?",
                arguments: [definitionID, runID]
            )
        }
    }

    static func applyFlowConstraintsMigration(db: Database) throws {
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_flow_definitions_canonical ON flow_definitions(canonicalFlowPath)")

        let orphanCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM flow_runs WHERE flowDefinitionId IS NULL OR flowDefinitionId = ''"
        ) ?? 0

        if orphanCount > 0 {
            try db.execute(
                sql: """
                    INSERT INTO flow_warnings (scope, flowRunId, flowDefinitionId, stateId, code, message, createdAt)
                    VALUES (?, NULL, NULL, NULL, ?, ?, ?)
                    """,
                arguments: [
                    FlowWarningScope.system.rawValue,
                    "flow.migration.backfill_path_unresolved",
                    "Flow migration left \(orphanCount) run rows without linked flow_definition.",
                    Date()
                ]
            )
        }
    }

    private static func upsertDefinitionForBackfill(
        db: Database,
        resolvedPath: FlowResolvedDefinitionPath
    ) throws -> String {
        if let existingID = try String.fetchOne(
            db,
            sql: "SELECT id FROM flow_definitions WHERE canonicalFlowPath = ? LIMIT 1",
            arguments: [resolvedPath.canonicalPath]
        ) {
            return existingID
        }

        var candidateName = resolvedPath.suggestedName.isEmpty ? "flow" : resolvedPath.suggestedName
        let nameConflict = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM flow_definitions WHERE lower(name) = lower(?)",
            arguments: [candidateName]
        ) ?? 0
        if nameConflict > 0 {
            candidateName += "-\(UUID().uuidString.prefix(8).lowercased())"
        }

        let now = Date()
        let id = UUID().uuidString.lowercased()
        try db.execute(
            sql: """
                INSERT INTO flow_definitions (
                  id, name, displayFlowPath, canonicalFlowPath, workspacePath,
                  tagsJSON, isPinned, createdAt, updatedAt, lastValidatedAt, lastCompiledAt, lastRunAt
                )
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, NULL, NULL, NULL)
                """,
            arguments: [
                id,
                candidateName,
                resolvedPath.displayPath,
                resolvedPath.canonicalPath,
                resolvedPath.workspacePath,
                "[]",
                now,
                now
            ]
        )
        return id
    }

    private static func tableExists(db: Database, name: String) throws -> Bool {
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?"
        let count = try Int.fetchOne(db, sql: sql, arguments: [name]) ?? 0
        return count > 0
    }

    private static func columnExists(db: Database, table: String, column: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        for row in rows {
            let name: String = row["name"]
            if name == column {
                return true
            }
        }
        return false
    }

    // MARK: - Flow Definitions

    public func upsertFlowDefinition(
        flowPath: String,
        name: String? = nil,
        tags: [String] = []
    ) throws -> FlowDefinitionRecord {
        let resolved = try FlowDefinitionPathResolver.resolve(rawPath: flowPath, requireFileExists: false)
        let now = Date()

        return try dbPool.write { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM flow_definitions WHERE canonicalFlowPath = ? LIMIT 1",
                arguments: [resolved.canonicalPath]
            ) {
                var existing = self.flowDefinitionFromRow(row)
                existing.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? existing.name
                if !tags.isEmpty {
                    existing.tags = tags
                }
                existing.displayFlowPath = resolved.displayPath
                existing.workspacePath = resolved.workspacePath
                existing.updatedAt = now

                try db.execute(
                    sql: """
                        UPDATE flow_definitions
                        SET name=?, displayFlowPath=?, workspacePath=?, tagsJSON=?, updatedAt=?
                        WHERE id=?
                        """,
                    arguments: [
                        existing.name,
                        existing.displayFlowPath,
                        existing.workspacePath,
                        try self.encodeJSONArray(existing.tags),
                        existing.updatedAt,
                        existing.id.uuidString.lowercased()
                    ]
                )
                return existing
            }

            let record = FlowDefinitionRecord(
                id: UUID(),
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? resolved.suggestedName,
                displayFlowPath: resolved.displayPath,
                canonicalFlowPath: resolved.canonicalPath,
                workspacePath: resolved.workspacePath,
                tags: tags,
                isPinned: false,
                createdAt: now,
                updatedAt: now,
                lastValidatedAt: nil,
                lastCompiledAt: nil,
                lastRunAt: nil
            )
            try db.execute(
                sql: """
                    INSERT INTO flow_definitions (
                      id, name, displayFlowPath, canonicalFlowPath, workspacePath,
                      tagsJSON, isPinned, createdAt, updatedAt, lastValidatedAt, lastCompiledAt, lastRunAt
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id.uuidString.lowercased(),
                    record.name,
                    record.displayFlowPath,
                    record.canonicalFlowPath,
                    record.workspacePath,
                    try self.encodeJSONArray(record.tags),
                    record.isPinned,
                    record.createdAt,
                    record.updatedAt,
                    record.lastValidatedAt,
                    record.lastCompiledAt,
                    record.lastRunAt
                ]
            )
            return record
        }
    }

    public func fetchAllFlowDefinitions() throws -> [FlowDefinitionRecord] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM flow_definitions ORDER BY isPinned DESC, updatedAt DESC, name COLLATE NOCASE"
            )
            return rows.map(self.flowDefinitionFromRow)
        }
    }

    public func fetchFlowDefinition(id: UUID) throws -> FlowDefinitionRecord? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM flow_definitions WHERE id = ? LIMIT 1",
                arguments: [id.uuidString.lowercased()]
            ) else {
                return nil
            }
            return self.flowDefinitionFromRow(row)
        }
    }

    public func fetchFlowDefinition(canonicalFlowPath: String) throws -> FlowDefinitionRecord? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM flow_definitions WHERE canonicalFlowPath = ? LIMIT 1",
                arguments: [canonicalFlowPath]
            ) else {
                return nil
            }
            return self.flowDefinitionFromRow(row)
        }
    }

    public func fetchFlowDefinitionSummaries() throws -> [FlowDefinitionStatusSummary] {
        try dbPool.read { db in
            let definitions = try Row.fetchAll(
                db,
                sql: "SELECT * FROM flow_definitions ORDER BY isPinned DESC, updatedAt DESC, name COLLATE NOCASE"
            )
            return try definitions.map { row in
                let definition = self.flowDefinitionFromRow(row)
                let latestRun = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT status, errorCode, startedAt, steps
                        FROM flow_runs
                        WHERE flowDefinitionId = ?
                        ORDER BY startedAt DESC
                        LIMIT 1
                        """,
                    arguments: [definition.id.uuidString.lowercased()]
                )
                let statusRaw: String? = latestRun?["status"]
                let status = statusRaw.flatMap(FlowRunRecordStatus.init(rawValue:))
                let errorCode: String? = latestRun?["errorCode"]
                let startedAt: Date? = latestRun?["startedAt"]
                let steps: Int? = latestRun?["steps"]
                return FlowDefinitionStatusSummary(
                    definition: definition,
                    latestRunStatus: status,
                    latestErrorCode: errorCode,
                    latestRunAt: startedAt,
                    latestSteps: steps
                )
            }
        }
    }

    public func markFlowDefinitionValidated(id: UUID, at date: Date = Date()) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE flow_definitions SET lastValidatedAt=?, updatedAt=? WHERE id=?",
                arguments: [date, date, id.uuidString.lowercased()]
            )
        }
    }

    public func markFlowDefinitionCompiled(id: UUID, at date: Date = Date()) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE flow_definitions SET lastCompiledAt=?, updatedAt=? WHERE id=?",
                arguments: [date, date, id.uuidString.lowercased()]
            )
        }
    }

    public func markFlowDefinitionRan(id: UUID, at date: Date = Date()) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE flow_definitions SET lastRunAt=?, updatedAt=? WHERE id=?",
                arguments: [date, date, id.uuidString.lowercased()]
            )
        }
    }

    // MARK: - Flow Runs

    public func insertFlowRun(_ run: FlowRunRecord) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO flow_runs (
                      id, flowDefinitionId, flowPathSnapshot, mode, startedAt, finishedAt, status, endedAtState, steps,
                      errorCode, errorMessage, provider, model, executablePath, executableSource,
                      commandsQueued, commandsConsumed, commandEventsTruncated, commandEventsTruncatedCount
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    run.id.uuidString.lowercased(),
                    run.flowDefinitionID.uuidString.lowercased(),
                    run.flowPathSnapshot,
                    run.mode.rawValue,
                    run.startedAt,
                    run.finishedAt,
                    run.status.rawValue,
                    run.endedAtState,
                    run.steps,
                    run.errorCode,
                    run.errorMessage,
                    run.provider,
                    run.model,
                    run.executablePath,
                    run.executableSource,
                    run.commandsQueued,
                    run.commandsConsumed,
                    run.commandEventsTruncated,
                    run.commandEventsTruncatedCount
                ]
            )
        }
    }

    public func updateFlowRun(_ run: FlowRunRecord) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE flow_runs
                    SET flowDefinitionId=?, flowPathSnapshot=?, mode=?, startedAt=?, finishedAt=?, status=?, endedAtState=?, steps=?,
                        errorCode=?, errorMessage=?, provider=?, model=?, executablePath=?, executableSource=?,
                        commandsQueued=?, commandsConsumed=?, commandEventsTruncated=?, commandEventsTruncatedCount=?
                    WHERE id=?
                    """,
                arguments: [
                    run.flowDefinitionID.uuidString.lowercased(),
                    run.flowPathSnapshot,
                    run.mode.rawValue,
                    run.startedAt,
                    run.finishedAt,
                    run.status.rawValue,
                    run.endedAtState,
                    run.steps,
                    run.errorCode,
                    run.errorMessage,
                    run.provider,
                    run.model,
                    run.executablePath,
                    run.executableSource,
                    run.commandsQueued,
                    run.commandsConsumed,
                    run.commandEventsTruncated,
                    run.commandEventsTruncatedCount,
                    run.id.uuidString.lowercased()
                ]
            )
        }
    }

    public func fetchFlowRun(id: UUID) throws -> FlowRunRecord? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM flow_runs WHERE id = ? LIMIT 1",
                arguments: [id.uuidString.lowercased()]
            ) else {
                return nil
            }
            return self.flowRunFromRow(row)
        }
    }

    public func fetchFlowRuns(flowDefinitionID: UUID, limit: Int = 50) throws -> [FlowRunRecord] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM flow_runs
                    WHERE flowDefinitionId = ?
                    ORDER BY startedAt DESC
                    LIMIT ?
                    """,
                arguments: [flowDefinitionID.uuidString.lowercased(), limit]
            )
            return rows.map(self.flowRunFromRow)
        }
    }

    public func fetchLatestFlowRun(flowDefinitionID: UUID) throws -> FlowRunRecord? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM flow_runs
                    WHERE flowDefinitionId = ?
                    ORDER BY startedAt DESC
                    LIMIT 1
                    """,
                arguments: [flowDefinitionID.uuidString.lowercased()]
            ) else {
                return nil
            }
            return self.flowRunFromRow(row)
        }
    }

    // MARK: - Flow Steps / Warnings / Commands

    public func insertFlowStep(runID: UUID, event: FlowStepChangedEvent) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO flow_steps (
                      flowRunId, seq, phase, stateId, stateType, attempt, decision, transition, duration,
                      counterJSON, stateOutputJSON, contextDeltaJSON, stateLastJSON,
                      errorCode, errorMessage, createdAt
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    runID.uuidString.lowercased(),
                    event.seq,
                    event.phase.rawValue,
                    event.stateID,
                    event.stateType,
                    event.attempt,
                    event.decision,
                    event.transition,
                    event.duration,
                    try encodeJSON(event.counter),
                    try encodeJSON(event.stateOutput),
                    try encodeJSON(event.contextDelta),
                    try encodeJSON(event.stateLast),
                    event.error?.code,
                    event.error?.message,
                    Date()
                ]
            )
        }
    }

    public func fetchFlowSteps(flowRunID: UUID) throws -> [FlowStepRecord] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM flow_steps WHERE flowRunId = ? ORDER BY seq ASC, id ASC",
                arguments: [flowRunID.uuidString.lowercased()]
            )
            return rows.map(self.flowStepFromRow)
        }
    }

    @discardableResult
    public func insertFlowWarning(
        scope: FlowWarningScope,
        flowRunID: UUID?,
        flowDefinitionID: UUID?,
        stateID: String?,
        code: String,
        message: String,
        createdAt: Date = Date()
    ) throws -> Int64 {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO flow_warnings (scope, flowRunId, flowDefinitionId, stateId, code, message, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    scope.rawValue,
                    flowRunID?.uuidString.lowercased(),
                    flowDefinitionID?.uuidString.lowercased(),
                    stateID,
                    code,
                    message,
                    createdAt
                ]
            )
            return db.lastInsertedRowID
        }
    }

    public func fetchFlowWarnings(flowRunID: UUID) throws -> [FlowWarningRecord] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM flow_warnings
                    WHERE flowRunId = ?
                    ORDER BY createdAt ASC, id ASC
                    """,
                arguments: [flowRunID.uuidString.lowercased()]
            )
            return rows.map(self.flowWarningFromRow)
        }
    }

    public func fetchFlowWarnings(flowDefinitionID: UUID) throws -> [FlowWarningRecord] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM flow_warnings
                    WHERE flowDefinitionId = ?
                    ORDER BY createdAt DESC, id DESC
                    """,
                arguments: [flowDefinitionID.uuidString.lowercased()]
            )
            return rows.map(self.flowWarningFromRow)
        }
    }

    public func insertFlowCommandEvent(runID: UUID, event: FlowCommandQueueChangedEvent) throws {
        try dbPool.write { db in
            let preview = event.commandPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            let commandHash = Self.hashForCommand(preview)
            try db.execute(
                sql: """
                    INSERT INTO flow_command_events (
                      flowRunId, seq, action, commandPreview, commandHash, queueDepth, stateId, turnId, reason, createdAt
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    runID.uuidString.lowercased(),
                    event.seq,
                    event.action.rawValue,
                    String(preview.prefix(240)),
                    commandHash,
                    event.queueDepth,
                    event.stateID,
                    event.turnID,
                    event.reason,
                    Date()
                ]
            )

            if event.action == .queued {
                try db.execute(
                    sql: "UPDATE flow_runs SET commandsQueued = commandsQueued + 1 WHERE id = ?",
                    arguments: [runID.uuidString.lowercased()]
                )
            }
            if event.action == .consumed {
                try db.execute(
                    sql: "UPDATE flow_runs SET commandsConsumed = commandsConsumed + 1 WHERE id = ?",
                    arguments: [runID.uuidString.lowercased()]
                )
            }

            try enforceCommandEventRollingWindow(db: db, runID: runID)
        }
    }

    private func enforceCommandEventRollingWindow(db: Database, runID: UUID) throws {
        let runIDText = runID.uuidString.lowercased()
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM flow_command_events WHERE flowRunId = ?",
            arguments: [runIDText]
        ) ?? 0
        let overflow = count - 1000
        guard overflow > 0 else { return }

        let alreadyTruncated = (try Bool.fetchOne(
            db,
            sql: "SELECT commandEventsTruncated FROM flow_runs WHERE id = ?",
            arguments: [runIDText]
        )) ?? false

        try db.execute(
            sql: """
                DELETE FROM flow_command_events
                WHERE id IN (
                  SELECT id FROM flow_command_events
                  WHERE flowRunId = ?
                  ORDER BY seq ASC, id ASC
                  LIMIT ?
                )
                """,
            arguments: [runIDText, overflow]
        )

        try db.execute(
            sql: """
                UPDATE flow_runs
                SET commandEventsTruncated = 1,
                    commandEventsTruncatedCount = commandEventsTruncatedCount + ?
                WHERE id = ?
                """,
            arguments: [overflow, runIDText]
        )

        if !alreadyTruncated {
            try db.execute(
                sql: """
                    INSERT INTO flow_warnings (scope, flowRunId, flowDefinitionId, stateId, code, message, createdAt)
                    VALUES (?, ?, NULL, NULL, ?, ?, ?)
                    """,
                arguments: [
                    FlowWarningScope.run.rawValue,
                    runIDText,
                    "flow.command.events_truncated",
                    "Flow command events exceeded 1000 entries and oldest events were truncated.",
                    Date()
                ]
            )
        }
    }

    public func fetchFlowCommandEvents(flowRunID: UUID, limit: Int = 1000) throws -> [FlowCommandEventRecord] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM flow_command_events
                    WHERE flowRunId = ?
                    ORDER BY seq ASC, id ASC
                    LIMIT ?
                    """,
                arguments: [flowRunID.uuidString.lowercased(), limit]
            )
            return rows.map(self.flowCommandEventFromRow)
        }
    }

    public func cleanupFlowCommandEvents(olderThanDays days: Int = 30) throws -> Int {
        try dbPool.write { db in
            let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
            try db.execute(
                sql: "DELETE FROM flow_command_events WHERE createdAt < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

    // MARK: - Compile Artifacts

    @discardableResult
    public func insertFlowCompileArtifact(
        flowDefinitionID: UUID,
        sourceFlowPath: String,
        sourceFlowHash: String,
        outputPath: String,
        outputHash: String,
        fileSize: Int64,
        createdAt: Date = Date()
    ) throws -> Int64 {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO flow_compile_artifacts (
                      flowDefinitionId, sourceFlowPath, sourceFlowHash, outputPath, outputHash, fileSize, createdAt
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    flowDefinitionID.uuidString.lowercased(),
                    sourceFlowPath,
                    sourceFlowHash,
                    outputPath,
                    outputHash,
                    fileSize,
                    createdAt
                ]
            )
            return db.lastInsertedRowID
        }
    }

    public func pruneFlowCompileArtifacts(
        maxPerFlow: Int = 20,
        maxAgeDays: Int = 30,
        maxTotalBytes: Int64 = 1_000_000_000
    ) throws -> Int {
        try dbPool.write { db in
            var removedArtifactPaths: [String] = []

            let definitionIDs = try String.fetchAll(db, sql: "SELECT id FROM flow_definitions")
            for definitionID in definitionIDs {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, outputPath
                        FROM flow_compile_artifacts
                        WHERE flowDefinitionId = ?
                        ORDER BY createdAt DESC, id DESC
                        """,
                    arguments: [definitionID]
                )
                if rows.count > maxPerFlow {
                    for row in rows[maxPerFlow...] {
                        let id: Int64 = row["id"]
                        let outputPath: String = row["outputPath"]
                        try db.execute(
                            sql: "DELETE FROM flow_compile_artifacts WHERE id = ?",
                            arguments: [id]
                        )
                        removedArtifactPaths.append(outputPath)
                    }
                }
            }

            let cutoff = Date().addingTimeInterval(TimeInterval(-maxAgeDays * 24 * 60 * 60))
            let agedRows = try Row.fetchAll(
                db,
                sql: "SELECT id, outputPath FROM flow_compile_artifacts WHERE createdAt < ?",
                arguments: [cutoff]
            )
            for row in agedRows {
                let id: Int64 = row["id"]
                let outputPath: String = row["outputPath"]
                try db.execute(
                    sql: "DELETE FROM flow_compile_artifacts WHERE id = ?",
                    arguments: [id]
                )
                removedArtifactPaths.append(outputPath)
            }

            var totalBytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(fileSize), 0) FROM flow_compile_artifacts") ?? 0
            if totalBytes > maxTotalBytes {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, outputPath, fileSize FROM flow_compile_artifacts ORDER BY createdAt ASC, id ASC"
                )
                for row in rows where totalBytes > maxTotalBytes {
                    let id: Int64 = row["id"]
                    let outputPath: String = row["outputPath"]
                    let fileSize: Int64 = row["fileSize"]
                    try db.execute(
                        sql: "DELETE FROM flow_compile_artifacts WHERE id = ?",
                        arguments: [id]
                    )
                    removedArtifactPaths.append(outputPath)
                    totalBytes -= fileSize
                }
            }

            for outputPath in removedArtifactPaths {
                try? FileManager.default.removeItem(atPath: outputPath)
            }

            return removedArtifactPaths.count
        }
    }

    public func fetchFlowCompileArtifacts(flowDefinitionID: UUID, limit: Int = 50) throws -> [FlowCompileArtifactRecord] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM flow_compile_artifacts
                    WHERE flowDefinitionId = ?
                    ORDER BY createdAt DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [flowDefinitionID.uuidString.lowercased(), limit]
            )
            return rows.map(self.flowCompileArtifactFromRow)
        }
    }

    // MARK: - Diagnostics

    public func isFlowSchemaReady() throws -> Bool {
        try dbPool.read { db in
            let tables = [
                "flow_definitions",
                "flow_runs",
                "flow_steps",
                "flow_warnings",
                "flow_command_events",
                "flow_compile_artifacts"
            ]
            for table in tables {
                if (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
                    arguments: [table]
                ) ?? 0) == 0 {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Flow Row Mapping

    private func flowDefinitionFromRow(_ row: Row) -> FlowDefinitionRecord {
        let idText: String = row["id"]
        return FlowDefinitionRecord(
            id: UUID(uuidString: idText)!,
            name: row["name"],
            displayFlowPath: row["displayFlowPath"],
            canonicalFlowPath: row["canonicalFlowPath"],
            workspacePath: row["workspacePath"],
            tags: (try? decodeJSONArray(row["tagsJSON"])) ?? [],
            isPinned: row["isPinned"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            lastValidatedAt: row["lastValidatedAt"],
            lastCompiledAt: row["lastCompiledAt"],
            lastRunAt: row["lastRunAt"]
        )
    }

    private func flowRunFromRow(_ row: Row) -> FlowRunRecord {
        FlowRunRecord(
            id: UUID(uuidString: row["id"])!,
            flowDefinitionID: UUID(uuidString: row["flowDefinitionId"])!,
            flowPathSnapshot: row["flowPathSnapshot"],
            mode: FlowRunRecordMode(rawValue: row["mode"]) ?? .live,
            startedAt: row["startedAt"],
            finishedAt: row["finishedAt"],
            status: FlowRunRecordStatus(rawValue: row["status"]) ?? .failure,
            endedAtState: row["endedAtState"],
            steps: row["steps"],
            errorCode: row["errorCode"],
            errorMessage: row["errorMessage"],
            provider: row["provider"],
            model: row["model"],
            executablePath: row["executablePath"],
            executableSource: row["executableSource"],
            commandsQueued: row["commandsQueued"],
            commandsConsumed: row["commandsConsumed"],
            commandEventsTruncated: row["commandEventsTruncated"],
            commandEventsTruncatedCount: row["commandEventsTruncatedCount"]
        )
    }

    private func flowStepFromRow(_ row: Row) -> FlowStepRecord {
        FlowStepRecord(
            id: row["id"],
            flowRunID: UUID(uuidString: row["flowRunId"])!,
            seq: row["seq"],
            phase: row["phase"],
            stateID: row["stateId"],
            stateType: row["stateType"],
            attempt: row["attempt"],
            decision: row["decision"],
            transition: row["transition"],
            duration: row["duration"],
            counterJSON: row["counterJSON"],
            stateOutputJSON: row["stateOutputJSON"],
            contextDeltaJSON: row["contextDeltaJSON"],
            stateLastJSON: row["stateLastJSON"],
            errorCode: row["errorCode"],
            errorMessage: row["errorMessage"],
            createdAt: row["createdAt"]
        )
    }

    private func flowWarningFromRow(_ row: Row) -> FlowWarningRecord {
        let runIDText: String? = row["flowRunId"]
        let definitionIDText: String? = row["flowDefinitionId"]
        return FlowWarningRecord(
            id: row["id"],
            scope: FlowWarningScope(rawValue: row["scope"]) ?? .run,
            flowRunID: runIDText.flatMap(UUID.init(uuidString:)),
            flowDefinitionID: definitionIDText.flatMap(UUID.init(uuidString:)),
            stateID: row["stateId"],
            code: row["code"],
            message: row["message"],
            createdAt: row["createdAt"]
        )
    }

    private func flowCommandEventFromRow(_ row: Row) -> FlowCommandEventRecord {
        FlowCommandEventRecord(
            id: row["id"],
            flowRunID: UUID(uuidString: row["flowRunId"])!,
            seq: row["seq"],
            action: FlowCommandQueueAction(rawValue: row["action"]) ?? .queued,
            commandPreview: row["commandPreview"],
            commandHash: row["commandHash"],
            queueDepth: row["queueDepth"],
            stateID: row["stateId"],
            turnID: row["turnId"],
            reason: row["reason"],
            createdAt: row["createdAt"]
        )
    }

    private func flowCompileArtifactFromRow(_ row: Row) -> FlowCompileArtifactRecord {
        FlowCompileArtifactRecord(
            id: row["id"],
            flowDefinitionID: UUID(uuidString: row["flowDefinitionId"])!,
            sourceFlowPath: row["sourceFlowPath"],
            sourceFlowHash: row["sourceFlowHash"],
            outputPath: row["outputPath"],
            outputHash: row["outputHash"],
            fileSize: row["fileSize"],
            createdAt: row["createdAt"]
        )
    }

    // MARK: - Flow JSON Utilities

    private func encodeJSONArray(_ array: [String]) throws -> String {
        let data = try JSONEncoder().encode(array)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FlowError(code: "flow.validate.schema_error", message: "Failed to encode tags", phase: .runtimePreflight)
        }
        return text
    }

    private func decodeJSONArray(_ json: String) throws -> [String] {
        let data = Data(json.utf8)
        return try JSONDecoder().decode([String].self, from: data)
    }

    private func encodeJSON<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)
    }

    static func hashForCommand(_ command: String) -> String {
        let digest = SHA256.hash(data: Data(command.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
