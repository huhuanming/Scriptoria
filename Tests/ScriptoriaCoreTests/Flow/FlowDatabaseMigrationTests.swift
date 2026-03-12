import Foundation
import GRDB
import Testing
@testable import ScriptoriaCore

@Suite("Flow Database Migration", .serialized)
struct FlowDatabaseMigrationTests {
    @Test("fresh install migration creates required flow schema")
    func testFreshInstallMigration() async throws {
        // fresh install
        try await withTestWorkspace(prefix: "flow-db-fresh-install") { workspace in
            let manager = try DatabaseManager(directory: workspace.defaultDataDir.path)
            #expect(try manager.isFlowSchemaReady())
        }
    }

    @Test("upgrade path keeps data and backfill links run to definition")
    func testUpgradeBackfillLink() async throws {
        // upgrade + backfill
        try await withTestWorkspace(prefix: "flow-db-upgrade-backfill") { workspace in
            let manager = try DatabaseManager(directory: workspace.defaultDataDir.path)
            let flowFile = try workspace.makeFile(
                relativePath: "flows/sample.yaml",
                content: """
                version: flow/v1
                start: done
                states:
                  - id: done
                    type: end
                    status: success
                """
            )

            let definition = try manager.upsertFlowDefinition(flowPath: flowFile)
            let run = FlowRunRecord(
                flowDefinitionID: definition.id,
                flowPathSnapshot: flowFile,
                mode: .dry,
                status: .running
            )
            try manager.insertFlowRun(run)

            // Simulate historical row that lost flowDefinitionId before M2_backfill_link.
            try manager.dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
                try db.execute(
                    sql: "UPDATE flow_runs SET flowDefinitionId = '' WHERE id = ?",
                    arguments: [run.id.uuidString.lowercased()]
                )
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try DatabaseManager.applyFlowBackfillMigration(db: db)
            }

            let linked = try manager.fetchFlowRun(id: run.id)
            #expect(linked != nil)
            #expect(linked?.flowDefinitionID == definition.id)
        }
    }

    @Test("rollback failure in migration transaction does not persist partial writes")
    func testRollbackBehavior() async throws {
        // rollback
        try await withTestWorkspace(prefix: "flow-db-rollback") { workspace in
            let manager = try DatabaseManager(directory: workspace.defaultDataDir.path)
            do {
                try manager.dbPool.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO flow_warnings (scope, flowRunId, flowDefinitionId, stateId, code, message, createdAt)
                            VALUES (?, NULL, NULL, NULL, ?, ?, ?)
                            """,
                        arguments: [
                            FlowWarningScope.system.rawValue,
                            "flow.migration.failed",
                            "forced rollback",
                            Date()
                        ]
                    )
                    struct ForcedRollback: Error {}
                    throw ForcedRollback()
                }
            } catch {
                // Expected: write transaction should rollback.
            }

            let count = try manager.dbPool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM flow_warnings WHERE code = ?",
                    arguments: ["flow.migration.failed"]
                ) ?? 0
            }
            #expect(count == 0)
        }
    }

    @Test("idempotent flow migration helpers can run repeatedly")
    func testIdempotentMigrationHelpers() async throws {
        // idempotent
        try await withTestWorkspace(prefix: "flow-db-idempotent") { workspace in
            let manager = try DatabaseManager(directory: workspace.defaultDataDir.path)
            try manager.dbPool.write { db in
                try DatabaseManager.applyFlowSchemaMigration(db: db)
                try DatabaseManager.applyFlowSchemaMigration(db: db)
                try DatabaseManager.applyFlowConstraintsMigration(db: db)
            }
            #expect(try manager.isFlowSchemaReady())
        }
    }
}
