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
    @Published var runningAgentScriptIds: Set<UUID> = []
    @Published var currentOutput: String = ""
    @Published var currentOutputScriptId: UUID?
    @Published var currentRunId: UUID?
    @Published var currentAgentRunId: UUID?
    @Published var latestWorkspaceMemoryPath: String?
    @Published var config: Config
    @Published var needsOnboarding: Bool

    private var store: ScriptStore
    private var scheduleStore: ScheduleStore
    private let runner = ScriptRunner()
    private var logManager: LogManager
    private var memoryManager: MemoryManager
    private var logWatcherSource: DispatchSourceFileSystemObject?
    private var activeAgentSessions: [UUID: PostScriptAgentSession] = [:]

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
        self.memoryManager = MemoryManager(config: loadedConfig)
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

    func runScript(_ script: Script, modelOverride: String? = nil) async {
        guard !runningAgentScriptIds.contains(script.id) else { return }

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
        updateRunningState()
        currentOutput = ""
        currentOutputScriptId = script.id

        // Insert a "running" record before execution starts
        let runId = UUID()
        currentRunId = runId
        var runRecord = ScriptRun(id: runId, scriptId: script.id, scriptTitle: script.title)
        try? await store.saveRunHistory(runRecord)
        let initialRunRecord = runRecord

        let result = try? await runner.runStreaming(script, runId: runId, logManager: logManager, onStart: { [weak self] pid in
            guard let self else { return }
            var updated = initialRunRecord
            updated.pid = pid
            Task { @MainActor in
                try? self.store.updateRunHistorySync(updated)
            }
        }) { [weak self] text, _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentOutput += text
            }
        }

        runningScriptIds.remove(script.id)
        updateRunningState()

        guard let result else { return }

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

        // Post-script agent stage
        await runAgentStage(script: script, scriptRun: runRecord, modelOverride: modelOverride)
    }

    func stopScript(_ scriptId: UUID) {
        if let run = try? store.fetchRunningRun(scriptId: scriptId),
           let pid = run.pid,
           ProcessManager.isRunning(pid: pid) {
            _ = ProcessManager.terminate(pid: pid)
        }

        if let session = activeAgentSessions[scriptId] {
            Task {
                try? await session.interrupt()
            }
        }
    }

    func steerAgent(scriptId: UUID, input: String) async {
        await sendAgentCommand(scriptId: scriptId, mode: .prompt, input: input)
    }

    func sendAgentCommand(scriptId: UUID, mode: AgentCommandMode, input: String) async {
        guard let session = activeAgentSessions[scriptId] else { return }
        guard let command = AgentCommandInput.from(mode: mode, input: input) else { return }
        do {
            switch command {
            case .steer(let text):
                try await session.steer(text)
            case .interrupt:
                try await session.interrupt()
            }
        } catch {
            currentOutput += "\n[steer-error] \(error.localizedDescription)\n"
        }
    }

    func summarizeWorkspaceMemory(for script: Script) async -> String? {
        let taskName = script.agentTaskName.isEmpty ? script.title : script.agentTaskName
        do {
            let path = try memoryManager.summarizeWorkspaceMemory(
                taskId: script.agentTaskId,
                taskName: taskName
            )
            latestWorkspaceMemoryPath = path
            return path
        } catch {
            currentOutput += "\n[workspace-memory-error] \(error.localizedDescription)\n"
            return nil
        }
    }

    // MARK: - Agent Stage

    private func runAgentStage(
        script: Script,
        scriptRun: ScriptRun,
        modelOverride: String?
    ) async {
        let taskName = script.agentTaskName.isEmpty ? script.title : script.agentTaskName
        let selectedModel = resolveModel(script: script, override: modelOverride)
        let workspaceMemory = memoryManager.readWorkspaceMemory(taskId: script.agentTaskId, taskName: taskName)
        let skillContent = readFileIfExists(path: script.skill)
        let developerInstructions = PostScriptAgentRunner.buildDeveloperInstructions(
            skillContent: clippedText(skillContent, max: 40_000),
            workspaceMemory: clippedText(workspaceMemory, max: 40_000)
        )

        let prompt = PostScriptAgentRunner.buildInitialPrompt(
            taskName: taskName,
            script: script,
            scriptRun: scriptRun
        )
        let workingDirectory = URL(fileURLWithPath: script.path).deletingLastPathComponent().path

        currentOutput += "\n\n=== Agent Stage (\(selectedModel)) ===\n"
        runningAgentScriptIds.insert(script.id)
        updateRunningState()

        do {
            let session = try await PostScriptAgentRunner.launch(
                options: PostScriptAgentLaunchOptions(
                    workingDirectory: workingDirectory,
                    model: selectedModel,
                    userPrompt: prompt,
                    developerInstructions: developerInstructions
                ),
                onEvent: { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        self.currentOutput += event.text
                    }
                }
            )
            activeAgentSessions[script.id] = session

            var agentRun = AgentRun(
                scriptId: script.id,
                scriptRunId: scriptRun.id,
                taskId: script.agentTaskId,
                taskName: taskName,
                model: selectedModel,
                threadId: await session.threadId,
                turnId: await session.turnId
            )
            currentAgentRunId = agentRun.id
            try? await store.saveAgentRun(agentRun)

            let agentResult = try await session.waitForCompletion()
            activeAgentSessions.removeValue(forKey: script.id)

            agentRun.threadId = agentResult.threadId
            agentRun.turnId = agentResult.turnId
            agentRun.finishedAt = agentResult.finishedAt
            agentRun.status = agentResult.status
            agentRun.finalMessage = agentResult.finalMessage
            agentRun.output = agentResult.output
            let taskMemoryPath = try memoryManager.writeTaskMemory(
                taskId: script.agentTaskId,
                taskName: taskName,
                script: script,
                scriptRun: scriptRun,
                agentResult: agentResult
            )
            agentRun.taskMemoryPath = taskMemoryPath
            try? await store.updateAgentRun(agentRun)

            currentOutput += "\n\n=== Agent \(agentResult.status.rawValue) ===\n"
            currentOutput += "Task Memory: \(taskMemoryPath)\n"
        } catch {
            currentOutput += "\n[agent-error] \(error.localizedDescription)\n"
        }

        activeAgentSessions.removeValue(forKey: script.id)
        runningAgentScriptIds.remove(script.id)
        updateRunningState()
    }

    private func resolveModel(script _: Script, override: String?) -> String {
        if let override {
            let value = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return AgentRuntimeCatalog.defaultModel
    }

    private func readFileIfExists(path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? String(contentsOfFile: trimmed, encoding: .utf8)
    }

    private func clippedText(_ text: String?, max: Int) -> String? {
        guard let text else { return nil }
        if text.count <= max { return text }
        return String(text.prefix(max)) + "\n\n[truncated]"
    }

    // MARK: - Logs / History

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
        memoryManager = MemoryManager(config: newConfig)
        await loadScripts()
    }

    private func updateRunningState() {
        isRunning = !runningScriptIds.isEmpty || !runningAgentScriptIds.isEmpty
    }
}
