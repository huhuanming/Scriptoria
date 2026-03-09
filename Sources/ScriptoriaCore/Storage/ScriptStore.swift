import Foundation

/// Central store for managing scripts - used by both CLI and GUI
public final class ScriptStore: @unchecked Sendable {
    private let db: DatabaseManager
    private var scripts: [Script] = []
    private let lock = NSLock()

    /// Create a store using an explicit directory
    public init(baseDirectory: String? = nil) {
        let dir = baseDirectory ?? Config.resolveDataDirectory()
        self.db = try! DatabaseManager(directory: dir)
    }

    /// Create a store using the directory from Config
    public convenience init(config: Config) {
        self.init(baseDirectory: config.dataDirectory)
    }

    /// Create a store using the saved config
    public static func fromConfig() -> ScriptStore {
        ScriptStore(config: Config.load())
    }

    // MARK: - Lifecycle

    /// Load scripts from database (and migrate JSON if needed)
    public func load() async throws {
        // databasePath is {dataDir}/db/scriptoria.db — go up two levels to get dataDir
        let dataDir = URL(fileURLWithPath: db.databasePath).deletingLastPathComponent().deletingLastPathComponent().path
        try db.migrateFromJSONIfNeeded(directory: dataDir)
        let loaded = try db.fetchAllScripts()
        lock.withLock { scripts = loaded }
    }

    /// Save is now a no-op since each mutation writes directly to SQLite
    public func save() async throws {
        // No-op: writes happen immediately in each mutation method
    }

    // MARK: - CRUD

    public func all() -> [Script] {
        lock.withLock { scripts }
    }

    public func get(id: UUID) -> Script? {
        lock.withLock { scripts.first { $0.id == id } }
    }

    public func get(title: String) -> Script? {
        let lower = title.lowercased()
        return lock.withLock { scripts.first { $0.title.lowercased() == lower } }
    }

    @discardableResult
    public func add(_ script: Script) async throws -> Script {
        try db.insertScript(script)
        lock.withLock { scripts.append(script) }
        return script
    }

    public func update(_ script: Script) async throws {
        try db.updateScript(script)
        lock.withLock {
            if let index = scripts.firstIndex(where: { $0.id == script.id }) {
                scripts[index] = script
                scripts[index].updatedAt = Date()
            }
        }
    }

    public func remove(id: UUID) async throws {
        try db.deleteScript(id: id)
        lock.withLock { scripts.removeAll { $0.id == id } }
    }

    // MARK: - Search & Filter

    public func search(query: String) -> [Script] {
        let lower = query.lowercased()
        return lock.withLock {
            scripts.filter { script in
                script.title.lowercased().contains(lower)
                || script.description.lowercased().contains(lower)
                || script.tags.contains { $0.lowercased().contains(lower) }
            }
        }
    }

    public func filter(tag: String) -> [Script] {
        let lower = tag.lowercased()
        return lock.withLock {
            scripts.filter { $0.tags.contains { $0.lowercased() == lower } }
        }
    }

    public func favorites() -> [Script] {
        lock.withLock { scripts.filter(\.isFavorite) }
    }

    public func recentlyRun(limit: Int = 10) -> [Script] {
        lock.withLock {
            scripts
                .filter { $0.lastRunAt != nil }
                .sorted { ($0.lastRunAt ?? .distantPast) > ($1.lastRunAt ?? .distantPast) }
                .prefix(limit)
                .map { $0 }
        }
    }

    public func allTags() -> [String] {
        let tags = lock.withLock { scripts.flatMap(\.tags) }
        return Array(Set(tags)).sorted()
    }

    // MARK: - Run Tracking

    public func recordRun(id: UUID, status: RunStatus) async throws {
        try db.recordRun(scriptId: id, status: status)
        lock.withLock {
            if let index = scripts.firstIndex(where: { $0.id == id }) {
                scripts[index].lastRunAt = Date()
                scripts[index].lastRunStatus = status
                scripts[index].runCount += 1
            }
        }
    }

    public func saveRunHistory(_ run: ScriptRun) async throws {
        try db.insertScriptRun(run)
    }

    /// Fetch run history for a specific script
    public func fetchRunHistory(scriptId: UUID, limit: Int = 50) throws -> [ScriptRun] {
        try db.fetchRunHistory(scriptId: scriptId, limit: limit)
    }

    /// Fetch all run history
    public func fetchAllRunHistory(limit: Int = 100) throws -> [ScriptRun] {
        try db.fetchAllRunHistory(limit: limit)
    }
}
