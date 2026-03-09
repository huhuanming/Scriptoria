import SwiftUI
import ScriptoriaCore

/// Observable app state shared across all views
@MainActor
final class AppState: ObservableObject {
    @Published var scripts: [Script] = []
    @Published var schedules: [Schedule] = []
    @Published var searchQuery: String = ""
    @Published var selectedScript: Script?
    @Published var selectedTag: String = "__all__"
    @Published var isRunning: Bool = false
    @Published var runningScriptIds: Set<UUID> = []
    @Published var currentOutput: String = ""
    @Published var currentOutputScriptId: UUID?
    @Published var config: Config
    @Published var needsOnboarding: Bool

    private var store: ScriptStore
    private var scheduleStore: ScheduleStore
    private let runner = ScriptRunner()

    var filteredScripts: [Script] {
        var result = scripts
        // Filter by tag (skip special sidebar items)
        if !selectedTag.hasPrefix("__") {
            result = result.filter { $0.tags.contains { $0.lowercased() == selectedTag.lowercased() } }
        }
        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
            }
        }
        return result
    }

    var favoriteScripts: [Script] {
        scripts.filter(\.isFavorite)
    }

    var recentScripts: [Script] {
        scripts
            .filter { $0.lastRunAt != nil }
            .sorted { ($0.lastRunAt ?? .distantPast) > ($1.lastRunAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    var allTags: [String] {
        Array(Set(scripts.flatMap(\.tags))).sorted()
    }

    init() {
        let loadedConfig = Config.load()
        self.config = loadedConfig
        self.store = ScriptStore(config: loadedConfig)
        self.scheduleStore = ScheduleStore(config: loadedConfig)
        // First launch: no pointer file exists yet
        let pointerPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.scriptoria/pointer.json"
        self.needsOnboarding = !FileManager.default.fileExists(atPath: pointerPath)
    }

    func loadScripts() async {
        do {
            try await store.load()
            scripts = store.all()
            try await scheduleStore.load()
            schedules = scheduleStore.all()
        } catch {
            print("Failed to load scripts: \(error)")
        }
    }

    // MARK: - Schedule Management

    func reloadSchedules() async {
        do {
            try await scheduleStore.load()
            schedules = scheduleStore.all()
        } catch {
            print("Failed to reload schedules: \(error)")
        }
    }

    func schedulesForScript(_ scriptId: UUID) -> [Schedule] {
        schedules.filter { $0.scriptId == scriptId }
    }

    func addSchedule(scriptId: UUID, type: ScheduleType) async {
        let schedule = Schedule(scriptId: scriptId, type: type)
        do {
            try await scheduleStore.add(schedule)
            try await scheduleStore.activate(schedule)
            schedules = scheduleStore.all()
        } catch {
            print("Failed to add schedule: \(error)")
        }
    }

    func removeSchedule(_ schedule: Schedule) async {
        do {
            try await scheduleStore.deactivate(schedule)
            try await scheduleStore.remove(id: schedule.id)
            schedules = scheduleStore.all()
        } catch {
            print("Failed to remove schedule: \(error)")
        }
    }

    func updateSchedule(_ schedule: Schedule, newType: ScheduleType) async {
        do {
            // Deactivate old, update type, reactivate
            try await scheduleStore.deactivate(schedule)
            var updated = schedule
            updated.type = newType
            try await scheduleStore.update(updated)
            try await scheduleStore.activate(updated)
            schedules = scheduleStore.all()
        } catch {
            print("Failed to update schedule: \(error)")
        }
    }

    func toggleSchedule(_ schedule: Schedule) async {
        do {
            if schedule.isEnabled {
                try await scheduleStore.deactivate(schedule)
            } else {
                try await scheduleStore.activate(schedule)
            }
            schedules = scheduleStore.all()
        } catch {
            print("Failed to toggle schedule: \(error)")
        }
    }

    func addScript(_ script: Script) async {
        do {
            try await store.add(script)
            scripts = store.all()
        } catch {
            print("Failed to add script: \(error)")
        }
    }

    func updateScript(_ script: Script) async {
        do {
            try await store.update(script)
            scripts = store.all()
        } catch {
            print("Failed to update script: \(error)")
        }
    }

    func removeScript(id: UUID) async {
        do {
            try await store.remove(id: id)
            if selectedScript?.id == id { selectedScript = nil }
            scripts = store.all()
        } catch {
            print("Failed to remove script: \(error)")
        }
    }

    func toggleFavorite(_ script: Script) async {
        var updated = script
        updated.isFavorite.toggle()
        await updateScript(updated)
    }

    func runScript(_ script: Script) async {
        runningScriptIds.insert(script.id)
        isRunning = true
        currentOutput = ""
        currentOutputScriptId = script.id

        let result = try? await runner.run(script)

        runningScriptIds.remove(script.id)
        isRunning = !runningScriptIds.isEmpty

        if let result {
            currentOutput = result.output
            if !result.errorOutput.isEmpty {
                currentOutput += "\n--- STDERR ---\n" + result.errorOutput
            }
            try? await store.recordRun(id: script.id, status: result.status)
            try? await store.saveRunHistory(result)
            scripts = store.all()

            if config.notifyOnCompletion {
                await NotificationManager.shared.notifyRunComplete(result)
            }
        }
    }

    func fetchRunHistory(scriptId: UUID) -> [ScriptRun] {
        (try? store.fetchRunHistory(scriptId: scriptId)) ?? []
    }

    func updateConfig(_ newConfig: Config) {
        config = newConfig
        try? newConfig.save()
    }

    /// Reload stores after data directory change
    func reloadWithConfig(_ newConfig: Config) async {
        config = newConfig
        store = ScriptStore(config: newConfig)
        scheduleStore = ScheduleStore(config: newConfig)
        await loadScripts()
    }
}
