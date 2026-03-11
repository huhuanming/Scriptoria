import Foundation
import GRDB

/// Manages the SQLite database for all Scriptoria data
public final class DatabaseManager: Sendable {
    let dbPool: DatabasePool

    /// The file path of the database
    public let databasePath: String

    /// Open (or create) the database in the `db/` subdirectory of the given data directory
    public init(directory: String) throws {
        let fm = FileManager.default
        let dbDir = "\(directory)/db"
        if !fm.fileExists(atPath: dbDir) {
            try fm.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        }

        let path = "\(dbDir)/scriptoria.db"
        self.databasePath = path

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.journalMode = .wal
        config.busyMode = .timeout(5)

        self.dbPool = try DatabasePool(path: path, configuration: config)
        try migrator.migrate(dbPool)
    }

    // MARK: - Schema Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // Config table (key-value)
            try db.create(table: "config") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text).notNull()
            }

            // Scripts table
            try db.create(table: "scripts") { t in
                t.primaryKey("id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("path", .text).notNull()
                t.column("interpreter", .text).notNull().defaults(to: "auto")
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastRunAt", .datetime)
                t.column("lastRunStatus", .text)
                t.column("runCount", .integer).notNull().defaults(to: 0)
            }

            // Tags table (normalized)
            try db.create(table: "script_tags") { t in
                t.column("scriptId", .text).notNull().references("scripts", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.primaryKey(["scriptId", "tag"])
            }
            try db.create(index: "idx_script_tags_tag", on: "script_tags", columns: ["tag"])

            // Schedules table
            try db.create(table: "schedules") { t in
                t.primaryKey("id", .text).notNull()
                t.column("scriptId", .text).notNull().references("scripts", onDelete: .cascade)
                t.column("typeJSON", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                t.column("nextRunAt", .datetime)
            }

            // Script runs table
            try db.create(table: "script_runs") { t in
                t.primaryKey("id", .text).notNull()
                t.column("scriptId", .text).notNull().references("scripts", onDelete: .cascade)
                t.column("scriptTitle", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("exitCode", .integer)
                t.column("output", .text).notNull().defaults(to: "")
                t.column("errorOutput", .text).notNull().defaults(to: "")
            }
            try db.create(
                index: "idx_script_runs_scriptId_startedAt",
                on: "script_runs",
                columns: ["scriptId", "startedAt"]
            )
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "scripts") { t in
                t.add(column: "skill", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "script_runs") { t in
                t.add(column: "pid", .integer)
            }
        }

        migrator.registerMigration("v4") { db in
            try db.create(table: "script_agent_profiles") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scriptId", .text)
                    .notNull()
                    .unique()
                    .references("scripts", onDelete: .cascade)
                t.column("taskName", .text).notNull().defaults(to: "")
                t.column("defaultModel", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_script_agent_profiles_scriptId",
                on: "script_agent_profiles",
                columns: ["scriptId"],
                unique: true
            )

            try db.create(table: "agent_runs") { t in
                t.primaryKey("id", .text).notNull()
                t.column("scriptId", .text).notNull().references("scripts", onDelete: .cascade)
                t.column("scriptRunId", .text).references("script_runs", onDelete: .setNull)
                t.column("taskId", .integer).references("script_agent_profiles", column: "id", onDelete: .setNull)
                t.column("taskName", .text).notNull().defaults(to: "")
                t.column("model", .text).notNull().defaults(to: "")
                t.column("threadId", .text).notNull()
                t.column("turnId", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("finalMessage", .text).notNull().defaults(to: "")
                t.column("output", .text).notNull().defaults(to: "")
                t.column("taskMemoryPath", .text)
            }
            try db.create(
                index: "idx_agent_runs_scriptId_startedAt",
                on: "agent_runs",
                columns: ["scriptId", "startedAt"]
            )
            try db.create(
                index: "idx_agent_runs_status_startedAt",
                on: "agent_runs",
                columns: ["status", "startedAt"]
            )

            let now = Date()
            let scriptRows = try Row.fetchAll(db, sql: "SELECT id, title, createdAt, updatedAt FROM scripts")
            for row in scriptRows {
                let scriptId: String = row["id"]
                let title: String = row["title"]
                let createdAt: Date = row["createdAt"]
                let updatedAt: Date = row["updatedAt"]
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO script_agent_profiles (scriptId, taskName, defaultModel, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [scriptId, title, "", createdAt, updatedAt > createdAt ? updatedAt : now]
                )
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "scripts") { t in
                t.add(column: "agentTriggerMode", .text)
                    .notNull()
                    .defaults(to: AgentTriggerMode.always.rawValue)
            }
        }

        migrator.registerMigration("v6_flow_m1_schema") { db in
            try Self.applyFlowSchemaMigration(db: db)
        }

        migrator.registerMigration("v6_flow_m2_backfill_link") { db in
            try Self.applyFlowBackfillMigration(db: db)
        }

        migrator.registerMigration("v6_flow_m3_constraints") { db in
            try Self.applyFlowConstraintsMigration(db: db)
        }

        return migrator
    }

    // MARK: - Config

    public func getConfig(key: String) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM config WHERE key = ?", arguments: [key])
        }
    }

    public func setConfig(key: String, value: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    // MARK: - Scripts

    public func fetchAllScripts() throws -> [Script] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM scripts ORDER BY title COLLATE NOCASE")
            return try rows.map { row in try self.scriptFromRow(row, db: db) }
        }
    }

    public func fetchScript(id: UUID) throws -> Script? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM scripts WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return try self.scriptFromRow(row, db: db)
        }
    }

    public func fetchScript(title: String) throws -> Script? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM scripts WHERE title = ? COLLATE NOCASE", arguments: [title]) else {
                return nil
            }
            return try self.scriptFromRow(row, db: db)
        }
    }

    public func searchScripts(query: String) throws -> [Script] {
        let pattern = "%\(query)%"
        return try dbPool.read { db in
            let sql = """
                SELECT DISTINCT s.* FROM scripts s
                LEFT JOIN script_tags t ON t.scriptId = s.id
                WHERE s.title LIKE ? COLLATE NOCASE
                   OR s.description LIKE ? COLLATE NOCASE
                   OR t.tag LIKE ? COLLATE NOCASE
                ORDER BY s.title COLLATE NOCASE
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [pattern, pattern, pattern])
            return try rows.map { row in try self.scriptFromRow(row, db: db) }
        }
    }

    public func filterScripts(tag: String) throws -> [Script] {
        return try dbPool.read { db in
            let sql = """
                SELECT s.* FROM scripts s
                INNER JOIN script_tags t ON t.scriptId = s.id
                WHERE t.tag = ? COLLATE NOCASE
                ORDER BY s.title COLLATE NOCASE
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [tag])
            return try rows.map { row in try self.scriptFromRow(row, db: db) }
        }
    }

    public func favoriteScripts() throws -> [Script] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM scripts WHERE isFavorite = 1 ORDER BY title COLLATE NOCASE")
            return try rows.map { row in try self.scriptFromRow(row, db: db) }
        }
    }

    public func recentlyRunScripts(limit: Int = 10) throws -> [Script] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM scripts WHERE lastRunAt IS NOT NULL ORDER BY lastRunAt DESC LIMIT ?", arguments: [limit])
            return try rows.map { row in try self.scriptFromRow(row, db: db) }
        }
    }

    public func allTags() throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT tag FROM script_tags ORDER BY tag COLLATE NOCASE")
        }
    }

    public func insertScript(_ script: Script) throws {
        try dbPool.write { db in
            try self.insertScriptRow(script, db: db)
        }
    }

    public func updateScript(_ script: Script) throws {
        try dbPool.write { db in
            var updated = script
            updated.updatedAt = Date()
            try db.execute(
                sql: """
                    UPDATE scripts SET title=?, description=?, path=?, skill=?, interpreter=?, agentTriggerMode=?,
                    isFavorite=?, createdAt=?, updatedAt=?, lastRunAt=?, lastRunStatus=?, runCount=?
                    WHERE id=?
                    """,
                arguments: [
                    updated.title, updated.description, updated.path,
                    updated.skill, updated.interpreter.rawValue, updated.agentTriggerMode.rawValue, updated.isFavorite,
                    updated.createdAt, updated.updatedAt,
                    updated.lastRunAt, updated.lastRunStatus?.rawValue,
                    updated.runCount, updated.id.uuidString
                ]
            )
            // Update tags
            try db.execute(sql: "DELETE FROM script_tags WHERE scriptId = ?", arguments: [updated.id.uuidString])
            for tag in updated.tags {
                try db.execute(
                    sql: "INSERT INTO script_tags (scriptId, tag) VALUES (?, ?)",
                    arguments: [updated.id.uuidString, tag]
                )
            }
            try self.upsertScriptAgentProfileRow(
                scriptId: updated.id,
                taskName: updated.agentTaskName.isEmpty ? updated.title : updated.agentTaskName,
                defaultModel: updated.defaultModel,
                db: db
            )
        }
    }

    public func deleteScript(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM script_tags WHERE scriptId = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM script_runs WHERE scriptId = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM schedules WHERE scriptId = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM scripts WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func recordRun(scriptId: UUID, status: RunStatus) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE scripts SET lastRunAt=?, lastRunStatus=?, runCount=runCount+1
                    WHERE id=?
                    """,
                arguments: [Date(), status.rawValue, scriptId.uuidString]
            )
        }
    }

    // MARK: - Script Runs

    public func insertScriptRun(_ run: ScriptRun) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO script_runs (id, scriptId, scriptTitle, startedAt, finishedAt, status, exitCode, output, errorOutput, pid)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    run.id.uuidString, run.scriptId.uuidString, run.scriptTitle,
                    run.startedAt, run.finishedAt, run.status.rawValue,
                    run.exitCode.map { Int($0) }, run.output, run.errorOutput,
                    run.pid.map { Int($0) }
                ]
            )
        }
    }

    public func updateScriptRun(_ run: ScriptRun) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE script_runs SET finishedAt=?, status=?, exitCode=?, output=?, errorOutput=?, pid=?
                    WHERE id=?
                    """,
                arguments: [
                    run.finishedAt, run.status.rawValue,
                    run.exitCode.map { Int($0) }, run.output, run.errorOutput,
                    run.pid.map { Int($0) },
                    run.id.uuidString
                ]
            )
        }
    }

    public func fetchScriptRun(id: UUID) throws -> ScriptRun? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM script_runs WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return self.scriptRunFromRow(row)
        }
    }

    public func fetchRunningRuns() throws -> [ScriptRun] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM script_runs WHERE status = ? ORDER BY startedAt DESC",
                arguments: [RunStatus.running.rawValue]
            )
            return rows.map { row in self.scriptRunFromRow(row) }
        }
    }

    /// Compute average duration (in seconds) for completed runs of a script
    public func fetchAverageDuration(scriptId: UUID) throws -> TimeInterval? {
        try dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT AVG(julianday(finishedAt) - julianday(startedAt)) * 86400.0 as avgDuration
                    FROM script_runs
                    WHERE scriptId = ? AND finishedAt IS NOT NULL AND status IN ('success', 'failure')
                    """,
                arguments: [scriptId.uuidString]
            )
            guard let row, let avg: Double = row["avgDuration"] else { return nil }
            return avg > 0 ? avg : nil
        }
    }

    /// Compute average duration (in seconds) for all scripts that have completed runs
    public func fetchAllAverageDurations() throws -> [UUID: TimeInterval] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT scriptId, AVG(julianday(finishedAt) - julianday(startedAt)) * 86400.0 as avgDuration
                    FROM script_runs
                    WHERE finishedAt IS NOT NULL AND status IN ('success', 'failure')
                    GROUP BY scriptId
                    """
            )
            var result: [UUID: TimeInterval] = [:]
            for row in rows {
                if let id = UUID(uuidString: row["scriptId"] as String),
                   let avg: Double = row["avgDuration"], avg > 0 {
                    result[id] = avg
                }
            }
            return result
        }
    }

    public func fetchRunningRun(scriptId: UUID) throws -> ScriptRun? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM script_runs WHERE scriptId = ? AND status = ? ORDER BY startedAt DESC LIMIT 1",
                arguments: [scriptId.uuidString, RunStatus.running.rawValue]
            ) else { return nil }
            return self.scriptRunFromRow(row)
        }
    }

    public func fetchRunHistory(scriptId: UUID, limit: Int = 50) throws -> [ScriptRun] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM script_runs WHERE scriptId = ? ORDER BY startedAt DESC LIMIT ?",
                arguments: [scriptId.uuidString, limit]
            )
            return rows.map { row in self.scriptRunFromRow(row) }
        }
    }

    public func fetchAllRunHistory(limit: Int = 100) throws -> [ScriptRun] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM script_runs ORDER BY startedAt DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.map { row in self.scriptRunFromRow(row) }
        }
    }

    // MARK: - Script Agent Profiles

    public func fetchScriptAgentProfile(scriptId: UUID) throws -> ScriptAgentProfile? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM script_agent_profiles WHERE scriptId = ?",
                arguments: [scriptId.uuidString]
            ) else { return nil }
            return self.scriptAgentProfileFromRow(row)
        }
    }

    public func fetchScriptAgentProfile(taskId: Int) throws -> ScriptAgentProfile? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM script_agent_profiles WHERE id = ?",
                arguments: [taskId]
            ) else { return nil }
            return self.scriptAgentProfileFromRow(row)
        }
    }

    public func upsertScriptAgentProfile(
        scriptId: UUID,
        taskName: String,
        defaultModel: String
    ) throws {
        try dbPool.write { db in
            try self.upsertScriptAgentProfileRow(
                scriptId: scriptId,
                taskName: taskName,
                defaultModel: defaultModel,
                db: db
            )
        }
    }

    // MARK: - Agent Runs

    public func insertAgentRun(_ run: AgentRun) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO agent_runs (
                        id, scriptId, scriptRunId, taskId, taskName, model, threadId, turnId,
                        startedAt, finishedAt, status, finalMessage, output, taskMemoryPath
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    run.id.uuidString,
                    run.scriptId.uuidString,
                    run.scriptRunId?.uuidString,
                    run.taskId,
                    run.taskName,
                    run.model,
                    run.threadId,
                    run.turnId,
                    run.startedAt,
                    run.finishedAt,
                    run.status.rawValue,
                    run.finalMessage,
                    run.output,
                    run.taskMemoryPath
                ]
            )
        }
    }

    public func updateAgentRun(_ run: AgentRun) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE agent_runs
                    SET scriptRunId=?, taskId=?, taskName=?, model=?, threadId=?, turnId=?,
                        finishedAt=?, status=?, finalMessage=?, output=?, taskMemoryPath=?
                    WHERE id=?
                    """,
                arguments: [
                    run.scriptRunId?.uuidString,
                    run.taskId,
                    run.taskName,
                    run.model,
                    run.threadId,
                    run.turnId,
                    run.finishedAt,
                    run.status.rawValue,
                    run.finalMessage,
                    run.output,
                    run.taskMemoryPath,
                    run.id.uuidString
                ]
            )
        }
    }

    public func fetchAgentRun(id: UUID) throws -> AgentRun? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM agent_runs WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return self.agentRunFromRow(row)
        }
    }

    public func fetchLatestAgentRun(scriptId: UUID) throws -> AgentRun? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM agent_runs WHERE scriptId = ? ORDER BY startedAt DESC LIMIT 1",
                arguments: [scriptId.uuidString]
            ) else { return nil }
            return self.agentRunFromRow(row)
        }
    }

    public func fetchAgentRuns(scriptId: UUID, limit: Int = 50) throws -> [AgentRun] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM agent_runs WHERE scriptId = ? ORDER BY startedAt DESC LIMIT ?",
                arguments: [scriptId.uuidString, limit]
            )
            return rows.map { self.agentRunFromRow($0) }
        }
    }

    // MARK: - Schedules

    public func fetchAllSchedules() throws -> [Schedule] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM schedules")
            return rows.compactMap { row in self.scheduleFromRow(row) }
        }
    }

    public func fetchSchedules(scriptId: UUID) throws -> [Schedule] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM schedules WHERE scriptId = ?", arguments: [scriptId.uuidString])
            return rows.compactMap { row in self.scheduleFromRow(row) }
        }
    }

    public func insertSchedule(_ schedule: Schedule) throws {
        try dbPool.write { db in
            let typeJSON = try Self.encodeScheduleType(schedule.type)
            try db.execute(
                sql: """
                    INSERT INTO schedules (id, scriptId, typeJSON, isEnabled, createdAt, nextRunAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    schedule.id.uuidString, schedule.scriptId.uuidString,
                    typeJSON, schedule.isEnabled, schedule.createdAt, schedule.nextRunAt
                ]
            )
        }
    }

    public func updateSchedule(_ schedule: Schedule) throws {
        try dbPool.write { db in
            let typeJSON = try Self.encodeScheduleType(schedule.type)
            try db.execute(
                sql: """
                    UPDATE schedules SET scriptId=?, typeJSON=?, isEnabled=?, createdAt=?, nextRunAt=?
                    WHERE id=?
                    """,
                arguments: [
                    schedule.scriptId.uuidString, typeJSON,
                    schedule.isEnabled, schedule.createdAt, schedule.nextRunAt,
                    schedule.id.uuidString
                ]
            )
        }
    }

    public func deleteSchedule(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM schedules WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func deleteSchedules(scriptId: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM schedules WHERE scriptId = ?", arguments: [scriptId.uuidString])
        }
    }

    // MARK: - Migration from JSON

    /// Migrate existing JSON data into SQLite. Returns true if migration occurred.
    @discardableResult
    public func migrateFromJSONIfNeeded(directory: String) throws -> Bool {
        let fm = FileManager.default
        let scriptsPath = "\(directory)/scripts.json"
        let schedulesPath = "\(directory)/schedules.json"
        let historyDir = "\(directory)/history"

        let hasScripts = fm.fileExists(atPath: scriptsPath)
        let hasSchedules = fm.fileExists(atPath: schedulesPath)

        guard hasScripts || hasSchedules else { return false }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try dbPool.write { db in
            // Migrate scripts
            if hasScripts, let data = try? Data(contentsOf: URL(fileURLWithPath: scriptsPath)) {
                if let scripts = try? decoder.decode([Script].self, from: data) {
                    for script in scripts {
                        // Skip if already exists
                        let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scripts WHERE id = ?", arguments: [script.id.uuidString]) ?? 0
                        if exists == 0 {
                            try self.insertScriptRow(script, db: db)
                        }
                    }
                }
            }

            // Migrate schedules
            if hasSchedules, let data = try? Data(contentsOf: URL(fileURLWithPath: schedulesPath)) {
                if let schedules = try? decoder.decode([Schedule].self, from: data) {
                    for schedule in schedules {
                        let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schedules WHERE id = ?", arguments: [schedule.id.uuidString]) ?? 0
                        if exists == 0 {
                            let typeJSON = try Self.encodeScheduleType(schedule.type)
                            try db.execute(
                                sql: "INSERT INTO schedules (id, scriptId, typeJSON, isEnabled, createdAt, nextRunAt) VALUES (?, ?, ?, ?, ?, ?)",
                                arguments: [schedule.id.uuidString, schedule.scriptId.uuidString, typeJSON, schedule.isEnabled, schedule.createdAt, schedule.nextRunAt]
                            )
                        }
                    }
                }
            }

            // Migrate history JSONL files
            if fm.fileExists(atPath: historyDir),
               let files = try? fm.contentsOfDirectory(atPath: historyDir) {
                for file in files where file.hasSuffix(".jsonl") {
                    let filePath = "\(historyDir)/\(file)"
                    if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                        for line in content.split(separator: "\n") where !line.isEmpty {
                            if let lineData = line.data(using: .utf8),
                               let run = try? decoder.decode(ScriptRun.self, from: lineData) {
                                let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM script_runs WHERE id = ?", arguments: [run.id.uuidString]) ?? 0
                                if exists == 0 {
                                    try db.execute(
                                        sql: "INSERT INTO script_runs (id, scriptId, scriptTitle, startedAt, finishedAt, status, exitCode, output, errorOutput) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                        arguments: [run.id.uuidString, run.scriptId.uuidString, run.scriptTitle, run.startedAt, run.finishedAt, run.status.rawValue, run.exitCode.map { Int($0) }, run.output, run.errorOutput]
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        // Rename old JSON files to .bak
        if hasScripts {
            try? fm.moveItem(atPath: scriptsPath, toPath: "\(scriptsPath).bak")
        }
        if hasSchedules {
            try? fm.moveItem(atPath: schedulesPath, toPath: "\(schedulesPath).bak")
        }
        if fm.fileExists(atPath: historyDir) {
            try? fm.moveItem(atPath: historyDir, toPath: "\(historyDir).bak")
        }

        // Also backup config.json (will be stored in SQLite going forward)
        let configPath = "\(directory)/config.json"
        if fm.fileExists(atPath: configPath) {
            try? fm.moveItem(atPath: configPath, toPath: "\(configPath).bak")
        }

        return true
    }

    // MARK: - Private Helpers

    private func insertScriptRow(_ script: Script, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO scripts (id, title, description, path, skill, interpreter, agentTriggerMode, isFavorite, createdAt, updatedAt, lastRunAt, lastRunStatus, runCount)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                script.id.uuidString, script.title, script.description, script.path,
                script.skill, script.interpreter.rawValue, script.agentTriggerMode.rawValue, script.isFavorite,
                script.createdAt, script.updatedAt,
                script.lastRunAt, script.lastRunStatus?.rawValue,
                script.runCount
            ]
        )
        for tag in script.tags {
            try db.execute(
                sql: "INSERT INTO script_tags (scriptId, tag) VALUES (?, ?)",
                arguments: [script.id.uuidString, tag]
            )
        }
        try upsertScriptAgentProfileRow(
            scriptId: script.id,
            taskName: script.agentTaskName.isEmpty ? script.title : script.agentTaskName,
            defaultModel: AgentRuntimeCatalog.normalizeModel(script.defaultModel),
            db: db
        )
    }

    private func scriptFromRow(_ row: Row, db: Database) throws -> Script {
        let idStr: String = row["id"]
        let id = UUID(uuidString: idStr)!
        let tags = try String.fetchAll(db, sql: "SELECT tag FROM script_tags WHERE scriptId = ? ORDER BY tag", arguments: [idStr])
        let statusStr: String? = row["lastRunStatus"]
        let profileRow = try Row.fetchOne(
            db,
            sql: "SELECT * FROM script_agent_profiles WHERE scriptId = ? LIMIT 1",
            arguments: [idStr]
        )
        let profile = profileRow.map(self.scriptAgentProfileFromRow)
        let taskName = profile?.taskName ?? (row["title"] as String)
        let defaultModel = AgentRuntimeCatalog.normalizeModel(profile?.defaultModel)
        let triggerModeRaw: String? = row["agentTriggerMode"]
        let triggerMode = triggerModeRaw.flatMap(AgentTriggerMode.init(rawValue:)) ?? .always

        return Script(
            id: id,
            title: row["title"],
            description: row["description"],
            path: row["path"],
            skill: row["skill"],
            agentTaskId: profile?.id,
            agentTaskName: taskName,
            defaultModel: defaultModel,
            agentTriggerMode: triggerMode,
            interpreter: Interpreter(rawValue: row["interpreter"]) ?? .auto,
            tags: tags,
            isFavorite: row["isFavorite"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            lastRunAt: row["lastRunAt"],
            lastRunStatus: statusStr.flatMap { RunStatus(rawValue: $0) },
            runCount: row["runCount"]
        )
    }

    private func scriptRunFromRow(_ row: Row) -> ScriptRun {
        let exitCodeInt: Int? = row["exitCode"]
        let pidInt: Int? = row["pid"]
        return ScriptRun(
            id: UUID(uuidString: row["id"] as String)!,
            scriptId: UUID(uuidString: row["scriptId"] as String)!,
            scriptTitle: row["scriptTitle"],
            startedAt: row["startedAt"],
            finishedAt: row["finishedAt"],
            status: RunStatus(rawValue: row["status"] as String) ?? .failure,
            exitCode: exitCodeInt.map { Int32($0) },
            output: row["output"],
            errorOutput: row["errorOutput"],
            pid: pidInt.map { Int32($0) }
        )
    }

    private func scriptAgentProfileFromRow(_ row: Row) -> ScriptAgentProfile {
        ScriptAgentProfile(
            id: row["id"],
            scriptId: UUID(uuidString: row["scriptId"] as String)!,
            taskName: row["taskName"],
            defaultModel: AgentRuntimeCatalog.normalizeModel(row["defaultModel"] as String),
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }

    private func agentRunFromRow(_ row: Row) -> AgentRun {
        let scriptRunIdStr: String? = row["scriptRunId"]
        return AgentRun(
            id: UUID(uuidString: row["id"] as String)!,
            scriptId: UUID(uuidString: row["scriptId"] as String)!,
            scriptRunId: scriptRunIdStr.flatMap(UUID.init(uuidString:)),
            taskId: row["taskId"],
            taskName: row["taskName"],
            model: row["model"],
            threadId: row["threadId"],
            turnId: row["turnId"],
            startedAt: row["startedAt"],
            finishedAt: row["finishedAt"],
            status: AgentRunStatus(rawValue: row["status"] as String) ?? .failed,
            finalMessage: row["finalMessage"],
            output: row["output"],
            taskMemoryPath: row["taskMemoryPath"]
        )
    }

    private func upsertScriptAgentProfileRow(
        scriptId: UUID,
        taskName: String,
        defaultModel: String,
        db: Database
    ) throws {
        let now = Date()
        let normalizedDefaultModel = AgentRuntimeCatalog.normalizeModel(defaultModel)
        try db.execute(
            sql: """
                INSERT INTO script_agent_profiles (scriptId, taskName, defaultModel, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(scriptId) DO UPDATE SET
                    taskName=excluded.taskName,
                    defaultModel=excluded.defaultModel,
                    updatedAt=excluded.updatedAt
                """,
            arguments: [scriptId.uuidString, taskName, normalizedDefaultModel, now, now]
        )
    }

    private func scheduleFromRow(_ row: Row) -> Schedule? {
        guard let id = UUID(uuidString: row["id"] as String),
              let scriptId = UUID(uuidString: row["scriptId"] as String),
              let typeJSON: String = row["typeJSON"],
              let type = try? Self.decodeScheduleType(typeJSON) else {
            return nil
        }

        return Schedule(
            id: id,
            scriptId: scriptId,
            type: type,
            isEnabled: row["isEnabled"],
            createdAt: row["createdAt"],
            nextRunAt: row["nextRunAt"]
        )
    }

    private static func encodeScheduleType(_ type: ScheduleType) throws -> String {
        let data = try JSONEncoder().encode(type)
        return String(data: data, encoding: .utf8)!
    }

    private static func decodeScheduleType(_ json: String) throws -> ScheduleType {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(ScheduleType.self, from: data)
    }
}
