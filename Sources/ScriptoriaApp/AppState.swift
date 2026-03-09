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
    @Published var currentRunId: UUID?
    @Published var config: Config
    @Published var needsOnboarding: Bool

    private var store: ScriptStore
    private var scheduleStore: ScheduleStore
    private let runner = ScriptRunner()
    private var logManager: LogManager
    private var logWatcherSource: DispatchSourceFileSystemObject?

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
        self.logManager = LogManager(config: loadedConfig)
        // First launch: no pointer file exists yet
        let pointerPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.scriptoria/pointer.json"
        self.needsOnboarding = !FileManager.default.fileExists(atPath: pointerPath)
        // Clean stale runs on startup
        ProcessManager.cleanStaleRuns(store: store)
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
        // Duplicate prevention: check if already running
        if let existingRun = try? store.fetchRunningRun(scriptId: script.id),
           let pid = existingRun.pid,
           ProcessManager.isRunning(pid: pid) {
            // Attach to existing run's log instead of starting a new one
            currentRunId = existingRun.id
            currentOutputScriptId = script.id
            if let logContent = logManager.readLog(for: existingRun.id) {
                currentOutput = logContent
            }
            startLogWatcher(for: existingRun.id)
            return
        }

        runningScriptIds.insert(script.id)
        isRunning = true
        currentOutput = ""
        currentOutputScriptId = script.id

        // Insert a "running" record before execution starts
        let runId = UUID()
        currentRunId = runId
        var runRecord = ScriptRun(id: runId, scriptId: script.id, scriptTitle: script.title)
        try? await store.saveRunHistory(runRecord)

        let result = try? await runner.runStreaming(script, runId: runId, logManager: logManager, onStart: { [weak self] pid in
            runRecord.pid = pid
            try? self?.store.updateRunHistorySync(runRecord)
        }) { [weak self] text, isStderr in
            Task { @MainActor in
                guard let self else { return }
                self.currentOutput += text
            }
        }

        runningScriptIds.remove(script.id)
        isRunning = !runningScriptIds.isEmpty

        if let result {
            // Update the run record with final result
            runRecord.output = result.output
            runRecord.errorOutput = result.errorOutput
            runRecord.exitCode = result.exitCode
            runRecord.finishedAt = result.finishedAt
            runRecord.status = result.status
            runRecord.pid = result.pid
            try? await store.updateRunHistory(runRecord)

            currentOutput = result.output
            if !result.errorOutput.isEmpty {
                currentOutput += "\n--- STDERR ---\n" + result.errorOutput
            }
            try? await store.recordRun(id: script.id, status: result.status)
            scripts = store.all()

            if config.notifyOnCompletion {
                await NotificationManager.shared.notifyRunComplete(result)
            }
        }
    }

    func stopScript(_ scriptId: UUID) {
        if let run = try? store.fetchRunningRun(scriptId: scriptId),
           let pid = run.pid,
           ProcessManager.isRunning(pid: pid) {
            _ = ProcessManager.terminate(pid: pid)
        }
    }

    /// Watch a log file for changes and update currentOutput
    private func startLogWatcher(for runId: UUID) {
        stopLogWatcher()
        let path = logManager.logPath(for: runId)

        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return }
        // Seek to current end so we only get new data via the watcher
        fileHandle.seekToEndOfFile()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileHandle.fileDescriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            let data = fileHandle.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                self?.currentOutput += text
            }
        }
        source.setCancelHandler {
            fileHandle.closeFile()
        }
        source.resume()
        logWatcherSource = source
    }

    private func stopLogWatcher() {
        logWatcherSource?.cancel()
        logWatcherSource = nil
    }

    func fetchRunHistory(scriptId: UUID) -> [ScriptRun] {
        (try? store.fetchRunHistory(scriptId: scriptId)) ?? []
    }

    func fetchAverageDuration(scriptId: UUID) -> TimeInterval? {
        try? store.fetchAverageDuration(scriptId: scriptId)
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
        logManager = LogManager(config: newConfig)
        await loadScripts()
    }
}
