import Foundation

/// Central store for managing scripts - used by both CLI and GUI
public final class ScriptStore: @unchecked Sendable {
    private let storage: StorageManager
    private var scripts: [Script] = []
    private let lock = NSLock()

    public init(baseDirectory: String? = nil) {
        self.storage = StorageManager(baseDirectory: baseDirectory)
    }

    // MARK: - Lifecycle

    /// Load scripts from disk
    public func load() async throws {
        try await storage.ensureDirectories()
        let path = await storage.scriptsFile
        do {
            let loaded: [Script] = try await storage.read([Script].self, from: path)
            lock.withLock { scripts = loaded }
        } catch {
            // File doesn't exist yet, start with empty
            lock.withLock { scripts = [] }
        }
    }

    /// Save scripts to disk
    public func save() async throws {
        let current = lock.withLock { scripts }
        let path = await storage.scriptsFile
        try await storage.write(current, to: path)
    }

    // MARK: - CRUD

    /// Get all scripts
    public func all() -> [Script] {
        lock.withLock { scripts }
    }

    /// Get a script by ID
    public func get(id: UUID) -> Script? {
        lock.withLock { scripts.first { $0.id == id } }
    }

    /// Get a script by title (case-insensitive)
    public func get(title: String) -> Script? {
        let lower = title.lowercased()
        return lock.withLock { scripts.first { $0.title.lowercased() == lower } }
    }

    /// Add a new script
    @discardableResult
    public func add(_ script: Script) async throws -> Script {
        lock.withLock { scripts.append(script) }
        try await save()
        return script
    }

    /// Update an existing script
    public func update(_ script: Script) async throws {
        lock.withLock {
            if let index = scripts.firstIndex(where: { $0.id == script.id }) {
                scripts[index] = script
                scripts[index].updatedAt = Date()
            }
        }
        try await save()
    }

    /// Remove a script by ID
    public func remove(id: UUID) async throws {
        lock.withLock { scripts.removeAll { $0.id == id } }
        try await save()
    }

    // MARK: - Search & Filter

    /// Search scripts by query string (matches title, description, tags)
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

    /// Filter scripts by tag
    public func filter(tag: String) -> [Script] {
        let lower = tag.lowercased()
        return lock.withLock {
            scripts.filter { $0.tags.contains { $0.lowercased() == lower } }
        }
    }

    /// Get favorite scripts
    public func favorites() -> [Script] {
        lock.withLock { scripts.filter(\.isFavorite) }
    }

    /// Get recently run scripts, sorted by last run date
    public func recentlyRun(limit: Int = 10) -> [Script] {
        lock.withLock {
            scripts
                .filter { $0.lastRunAt != nil }
                .sorted { ($0.lastRunAt ?? .distantPast) > ($1.lastRunAt ?? .distantPast) }
                .prefix(limit)
                .map { $0 }
        }
    }

    /// Get all unique tags
    public func allTags() -> [String] {
        let tags = lock.withLock { scripts.flatMap(\.tags) }
        return Array(Set(tags)).sorted()
    }

    // MARK: - Run Tracking

    /// Record that a script was run
    public func recordRun(id: UUID, status: RunStatus) async throws {
        lock.withLock {
            if let index = scripts.firstIndex(where: { $0.id == id }) {
                scripts[index].lastRunAt = Date()
                scripts[index].lastRunStatus = status
                scripts[index].runCount += 1
            }
        }
        try await save()
    }

    /// Save a run record to history
    public func saveRunHistory(_ run: ScriptRun) async throws {
        try await storage.appendHistory(run)
    }
}
