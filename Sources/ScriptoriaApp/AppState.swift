import SwiftUI
import ScriptoriaCore

struct FlowGraphEdgeRow: Identifiable, Sendable, Equatable {
    var id: String {
        "\(fromStateID)->\(label)->\(toStateID)"
    }

    var fromStateID: String
    var toStateID: String
    var label: String
}

struct FlowGraphNodeRow: Identifiable, Sendable, Equatable {
    var id: String { stateID }

    var stateID: String
    var stateType: String
    var isStart: Bool
    var outgoing: [FlowGraphEdgeRow]
}

struct FlowDryFixtureStateProgressRow: Identifiable, Sendable, Equatable {
    var id: String { stateID }

    var stateID: String
    var stateType: String?
    var totalItems: Int
    var consumedItems: Int
    var isUnknownState: Bool
    var hasUnusedStateWarning: Bool
    var hasUnconsumedItemsError: Bool
    var hasMissingStateDataError: Bool

    var remainingItems: Int {
        max(totalItems - consumedItems, 0)
    }
}

struct FlowDryFixtureProgressSummary: Sendable, Equatable {
    var fixturePath: String
    var totalItems: Int
    var consumedItems: Int
    var rows: [FlowDryFixtureStateProgressRow]

    var remainingItems: Int {
        max(totalItems - consumedItems, 0)
    }
}

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
    @Published var flowWorkbenchMode: FlowWorkbenchMode = .diagnosticsOnly
    @Published var flowDefinitions: [FlowDefinitionStatusSummary] = []
    @Published var selectedFlowDefinitionID: UUID?
    @Published var activeFlowRun: FlowRunRecord?
    @Published var activeFlowSteps: [FlowStepChangedEvent] = []
    @Published var activeFlowWarnings: [FlowWarningRaisedEvent] = []
    @Published var activeFlowCommandEvents: [FlowCommandQueueChangedEvent] = []
    @Published var flowRunHistory: [FlowRunRecord] = []
    @Published var flowCurrentLog: String = ""
    @Published var flowLastError: String?
    @Published var flowLastErrorCode: String?
    @Published var flowLastErrorPhase: String?
    @Published var flowLastErrorStateID: String?
    @Published var flowLastErrorFieldPath: String?
    @Published var flowLastErrorLine: Int?
    @Published var flowLastErrorColumn: Int?
    @Published var flowIRPreview: FlowIR?
    @Published var flowGraphEdges: [FlowGraphEdgeRow] = []
    @Published var flowGraphNodes: [FlowGraphNodeRow] = []
    @Published var flowLastCompileOutputPath: String?
    @Published var flowLastCompilePreview: String = ""
    @Published var flowLastCompileCleanupCount: Int = 0
    @Published var flowDryFixtureProgress: FlowDryFixtureProgressSummary?
    @Published var flowDryFixtureProgressError: String?
    @Published var isFlowRunning: Bool = false
    @Published var config: Config
    @Published var needsOnboarding: Bool

    private var store: ScriptStore
    private var scheduleStore: ScheduleStore
    private var flowService: FlowExecutionService
    private let runner = ScriptRunner()
    private var logManager: LogManager
    private var memoryManager: MemoryManager
    private var logWatcherSource: DispatchSourceFileSystemObject?
    private var activeAgentSessions: [UUID: PostScriptAgentSession] = [:]
    private var flowCommandContinuation: AsyncStream<String>.Continuation?
    private var flowDryFixturePathByRunID: [UUID: String] = [:]
    private var activeDryFixturePath: String?
    private var flowDryFixtureTemplateByPath: [String: [String: Int]] = [:]

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

    var selectedFlowDefinition: FlowDefinitionStatusSummary? {
        guard let selectedFlowDefinitionID else { return nil }
        return flowDefinitions.first { $0.definition.id == selectedFlowDefinitionID }
    }

    init() {
        let loadedConfig = Config.load()
        self.config = loadedConfig
        self.store = ScriptStore(config: loadedConfig)
        self.scheduleStore = ScheduleStore(config: loadedConfig)
        self.flowService = FlowExecutionService(baseDirectory: loadedConfig.dataDirectory)
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
            await loadFlows()
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

        guard result.status == .success else { return }

        switch AgentTriggerEvaluator.evaluate(script: script, scriptRun: runRecord) {
        case .run:
            await runAgentStage(script: script, scriptRun: runRecord, modelOverride: modelOverride)
        case .skip(let reason):
            currentOutput += "\n\n=== Agent Stage Skipped ===\n\(reason)\n"
        case .invalid(let reason):
            currentOutput += "\n\n[agent-trigger-error] \(reason)\n"
        }
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
        flowService = FlowExecutionService(baseDirectory: newConfig.dataDirectory)
        logManager = LogManager(config: newConfig)
        memoryManager = MemoryManager(config: newConfig)
        await loadScripts()
    }

    // MARK: - Flow Workbench

    func loadFlows() async {
        flowWorkbenchMode = flowService.workbenchMode()
        do {
            _ = try await flowService.loadDefinitions()
            flowDefinitions = try flowService.listDefinitionSummaries()
            if selectedFlowDefinitionID == nil {
                selectedFlowDefinitionID = flowDefinitions.first?.definition.id
            }
            await reloadSelectedFlowHistory()
            await refreshFlowIRPreview()
        } catch {
            setFlowError(error)
            flowDefinitions = []
            flowRunHistory = []
        }
    }

    func importFlowDefinition(at flowPath: String, name: String? = nil) async {
        do {
            _ = try flowService.importDefinition(flowPath: flowPath, name: name)
            await loadFlows()
        } catch {
            setFlowError(error)
        }
    }

    func selectFlowDefinition(_ id: UUID?) async {
        selectedFlowDefinitionID = id
        await reloadSelectedFlowHistory()
        await refreshFlowIRPreview()
    }

    func reloadSelectedFlowHistory() async {
        guard let definition = selectedFlowDefinition?.definition else {
            flowRunHistory = []
            activeFlowRun = nil
            activeFlowSteps = []
            activeFlowWarnings = []
            activeFlowCommandEvents = []
            flowDryFixtureProgress = nil
            flowDryFixtureProgressError = nil
            return
        }
        do {
            flowRunHistory = try flowService.fetchRunHistory(definitionID: definition.id, limit: 100)
            if let first = flowRunHistory.first {
                selectFlowRun(first)
            } else {
                activeFlowRun = nil
                activeFlowSteps = []
                activeFlowWarnings = []
                activeFlowCommandEvents = []
                flowDryFixtureProgress = nil
                flowDryFixtureProgressError = nil
            }
        } catch {
            setFlowError(error)
            flowRunHistory = []
            activeFlowRun = nil
        }
    }

    func selectFlowRun(_ run: FlowRunRecord) {
        activeFlowRun = run
        do {
            let stepRecords = try flowService.fetchSteps(runID: run.id)
            activeFlowSteps = stepRecords.map { record in
                FlowStepChangedEvent(
                    runID: run.id.uuidString.lowercased(),
                    seq: record.seq,
                    phase: FlowPhase(rawValue: record.phase) ?? .runtime,
                    stateID: record.stateID,
                    stateType: record.stateType,
                    attempt: record.attempt,
                    decision: record.decision,
                    transition: record.transition,
                    counter: decodeJSON(record.counterJSON),
                    duration: record.duration,
                    error: (record.errorCode == nil && record.errorMessage == nil)
                        ? nil
                        : FlowRunStepError(
                            code: record.errorCode ?? "flow.validate.schema_error",
                            message: record.errorMessage ?? "",
                            fieldPath: nil,
                            line: nil,
                            column: nil
                        ),
                    stateOutput: decodeJSON(record.stateOutputJSON),
                    contextDelta: decodeJSON(record.contextDeltaJSON),
                    stateLast: decodeJSON(record.stateLastJSON)
                )
            }

            let warningRecords = try flowService.fetchWarnings(runID: run.id)
            activeFlowWarnings = warningRecords.map { record in
                FlowWarningRaisedEvent(
                    runID: run.id.uuidString.lowercased(),
                    code: record.code,
                    message: record.message,
                    scope: record.scope,
                    flowDefinitionID: record.flowDefinitionID?.uuidString.lowercased(),
                    stateID: record.stateID
                )
            }

            let commandRecords = try flowService.fetchCommandEvents(runID: run.id)
            activeFlowCommandEvents = commandRecords.map { record in
                FlowCommandQueueChangedEvent(
                    runID: run.id.uuidString.lowercased(),
                    seq: record.seq,
                    action: record.action,
                    commandPreview: record.commandPreview,
                    queueDepth: record.queueDepth,
                    stateID: record.stateID,
                    turnID: record.turnID,
                    reason: record.reason
                )
            }
            refreshFlowDryFixtureProgress()
        } catch {
            setFlowError(error)
        }
    }

    func validateSelectedFlow(noFSCheck: Bool = false) async {
        guard let definition = selectedFlowDefinition?.definition else { return }
        do {
            _ = try flowService.validate(
                flowPath: definition.canonicalFlowPath,
                noFSCheck: noFSCheck,
                registerDefinition: true
            )
            clearFlowError()
            await loadFlows()
            await refreshFlowIRPreview()
        } catch {
            setFlowError(error)
        }
    }

    func compileSelectedFlow(
        outputPath: String,
        noFSCheck: Bool = false
    ) async {
        guard let definition = selectedFlowDefinition?.definition else { return }
        do {
            let result = try flowService.compile(
                flowPath: definition.canonicalFlowPath,
                outputPath: outputPath,
                noFSCheck: noFSCheck,
                registerDefinition: true
            )
            flowLastCompileOutputPath = result.outputPath
            flowLastCompileCleanupCount = result.cleanedArtifactsCount
            flowLastCompilePreview = String(result.canonicalJSON.prefix(8000))
            clearFlowError()
            await loadFlows()
            await refreshFlowIRPreview()
        } catch {
            setFlowError(error)
        }
    }

    func runSelectedFlowLive(
        contextOverrides: [String: String] = [:],
        maxAgentRounds: Int? = nil,
        initialCommands: [String] = []
    ) async {
        guard let definition = selectedFlowDefinition?.definition else { return }
        guard flowWorkbenchMode == .full else {
            flowLastError = "Flow workbench is currently in diagnostics-only mode."
            return
        }

        flowCurrentLog = ""
        clearFlowError()
        activeFlowRun = nil
        activeFlowSteps = []
        activeFlowWarnings = []
        activeFlowCommandEvents = []
        activeDryFixturePath = nil
        flowDryFixtureProgress = nil
        flowDryFixtureProgressError = nil
        isFlowRunning = true

        let commandStream = AsyncStream<String> { continuation in
            flowCommandContinuation = continuation
        }

        do {
            let execution = try await flowService.runLive(
                flowPath: definition.canonicalFlowPath,
                options: .init(
                    contextOverrides: contextOverrides,
                    maxAgentRoundsCap: maxAgentRounds,
                    noSteer: false,
                    commands: initialCommands
                ),
                commandInput: commandStream,
                logSink: { [weak self] line in
                    Task { @MainActor in
                        self?.flowCurrentLog += line + "\n"
                    }
                },
                eventSink: { [weak self] event in
                    Task { @MainActor in
                        self?.applyFlowEvent(event)
                    }
                }
            )
            flowCommandContinuation?.finish()
            flowCommandContinuation = nil
            if let completedRun = try? flowService.fetchRunHistory(definitionID: execution.definitionID, limit: 1).first {
                selectFlowRun(completedRun)
            }
            await loadFlows()
            await reloadSelectedFlowHistory()
        } catch {
            flowCommandContinuation?.finish()
            flowCommandContinuation = nil
            setFlowError(error)
            await reloadSelectedFlowHistory()
        }

        isFlowRunning = false
    }

    func runSelectedFlowDry(fixturePath: String) async {
        guard let definition = selectedFlowDefinition?.definition else { return }
        guard flowWorkbenchMode == .full else {
            flowLastError = "Flow workbench is currently in diagnostics-only mode."
            return
        }

        let normalizedFixturePath = normalizePath(fixturePath)

        flowCurrentLog = ""
        clearFlowError()
        activeFlowRun = nil
        activeFlowSteps = []
        activeFlowWarnings = []
        activeFlowCommandEvents = []
        activeDryFixturePath = normalizedFixturePath
        refreshFlowDryFixtureProgress()
        isFlowRunning = true

        do {
            let execution = try await flowService.runDry(
                flowPath: definition.canonicalFlowPath,
                fixturePath: normalizedFixturePath,
                options: .init(),
                logSink: { [weak self] line in
                    Task { @MainActor in
                        self?.flowCurrentLog += line + "\n"
                    }
                },
                eventSink: { [weak self] event in
                    Task { @MainActor in
                        self?.applyFlowEvent(event)
                    }
                }
            )
            flowDryFixturePathByRunID[execution.runID] = normalizedFixturePath
            if let completedRun = try? flowService.fetchRunHistory(definitionID: execution.definitionID, limit: 1).first {
                selectFlowRun(completedRun)
            }
            await loadFlows()
            await reloadSelectedFlowHistory()
        } catch {
            setFlowError(error)
            await reloadSelectedFlowHistory()
        }

        isFlowRunning = false
        activeDryFixturePath = nil
    }

    func sendFlowCommand(_ raw: String) {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        flowCommandContinuation?.yield(command)
    }

    func interruptFlowRun() {
        sendFlowCommand("/interrupt")
    }

    private func applyFlowEvent(_ event: FlowRunEvent) {
        switch event {
        case .runStarted:
            break
        case .stepChanged(let step):
            activeFlowSteps.append(step)
            refreshFlowDryFixtureProgress()
        case .warningRaised(let warning):
            activeFlowWarnings.append(warning)
            refreshFlowDryFixtureProgress()
        case .commandQueueChanged(let commandEvent):
            activeFlowCommandEvents.append(commandEvent)
        case .runCompleted:
            refreshFlowDryFixtureProgress()
            break
        }
    }

    private func refreshFlowIRPreview() async {
        guard let definition = selectedFlowDefinition?.definition else {
            flowIRPreview = nil
            flowGraphEdges = []
            flowGraphNodes = []
            refreshFlowDryFixtureProgress()
            return
        }
        do {
            let ir = try FlowCompiler.compileFile(
                atPath: definition.canonicalFlowPath,
                options: .init(checkFileSystem: false)
            )
            flowIRPreview = ir
            flowGraphEdges = buildFlowGraphEdges(from: ir)
            flowGraphNodes = buildFlowGraphNodes(from: ir)
            refreshFlowDryFixtureProgress()
        } catch {
            flowIRPreview = nil
            flowGraphEdges = []
            flowGraphNodes = []
            refreshFlowDryFixtureProgress()
        }
    }

    private func buildFlowGraphEdges(from ir: FlowIR) -> [FlowGraphEdgeRow] {
        var rows: [FlowGraphEdgeRow] = []
        for state in ir.states {
            switch state.kind {
            case .gate:
                if let transitions = state.transitions {
                    rows.append(.init(fromStateID: state.id, toStateID: transitions.pass, label: "pass"))
                    rows.append(.init(fromStateID: state.id, toStateID: transitions.needsAgent, label: "needs_agent"))
                    rows.append(.init(fromStateID: state.id, toStateID: transitions.wait, label: "wait"))
                    rows.append(.init(fromStateID: state.id, toStateID: transitions.fail, label: "fail"))
                    if let parseError = transitions.parseError {
                        rows.append(.init(fromStateID: state.id, toStateID: parseError, label: "parse_error"))
                    }
                }
            case .agent, .wait, .script:
                if let next = state.next {
                    rows.append(.init(fromStateID: state.id, toStateID: next, label: "next"))
                }
            case .end:
                break
            }
        }
        return rows
    }

    private func buildFlowGraphNodes(from ir: FlowIR) -> [FlowGraphNodeRow] {
        let groupedEdges = Dictionary(grouping: buildFlowGraphEdges(from: ir), by: \.fromStateID)
        return ir.states.map { state in
            FlowGraphNodeRow(
                stateID: state.id,
                stateType: state.kind.rawValue,
                isStart: state.id == ir.start,
                outgoing: groupedEdges[state.id, default: []].sorted { lhs, rhs in
                    if lhs.label == rhs.label {
                        return lhs.toStateID < rhs.toStateID
                    }
                    return lhs.label < rhs.label
                }
            )
        }
    }

    private func refreshFlowDryFixtureProgress() {
        guard let fixturePath = resolveFixturePathForProgress() else {
            flowDryFixtureProgress = nil
            flowDryFixtureProgressError = nil
            return
        }

        do {
            let totals = try fixtureTotals(at: fixturePath)
            let flowStates = flowIRPreview?.states ?? []
            let flowStateOrder = Dictionary(uniqueKeysWithValues: flowStates.enumerated().map { ($1.id, $0) })
            let flowStateTypes = Dictionary(uniqueKeysWithValues: flowStates.map { ($0.id, $0.kind.rawValue) })
            let knownStateIDs = Set(flowStateTypes.keys)

            let consumableStateTypes: Set<String> = ["gate", "script", "agent"]
            let missingStateDataCode = "flow.dryrun.fixture_missing_state_data"

            var consumedByState: [String: Int] = [:]
            var missingStateDataStates: Set<String> = []
            var executedStates: Set<String> = []

            for step in activeFlowSteps {
                executedStates.insert(step.stateID)
                if step.error?.code == missingStateDataCode {
                    missingStateDataStates.insert(step.stateID)
                    continue
                }
                if consumableStateTypes.contains(step.stateType.lowercased()) {
                    consumedByState[step.stateID, default: 0] += 1
                }
            }

            let unusedWarningStates = Set(
                activeFlowWarnings
                    .filter { $0.code == "flow.dryrun.fixture_unused_state_data" }
                    .compactMap(\.stateID)
            )

            let hasUnconsumedItemsError =
                (activeFlowRun?.errorCode == "flow.dryrun.fixture_unconsumed_items")
                || activeFlowSteps.contains(where: { $0.error?.code == "flow.dryrun.fixture_unconsumed_items" })

            var rowStateIDs = Set(totals.keys)
            rowStateIDs.formUnion(consumedByState.keys)

            let sortedStateIDs = rowStateIDs.sorted { lhs, rhs in
                let lhsRank = flowStateOrder[lhs] ?? Int.max
                let rhsRank = flowStateOrder[rhs] ?? Int.max
                if lhsRank == rhsRank {
                    return lhs < rhs
                }
                return lhsRank < rhsRank
            }

            let rows = sortedStateIDs.map { stateID in
                let total = totals[stateID] ?? 0
                let consumed = min(consumedByState[stateID] ?? 0, total)
                let remaining = max(total - consumed, 0)
                let isUnknownState = !knownStateIDs.isEmpty && !knownStateIDs.contains(stateID)
                let hasUnconsumedItemsErrorForState = hasUnconsumedItemsError && executedStates.contains(stateID) && remaining > 0

                return FlowDryFixtureStateProgressRow(
                    stateID: stateID,
                    stateType: flowStateTypes[stateID],
                    totalItems: total,
                    consumedItems: consumed,
                    isUnknownState: isUnknownState,
                    hasUnusedStateWarning: unusedWarningStates.contains(stateID),
                    hasUnconsumedItemsError: hasUnconsumedItemsErrorForState,
                    hasMissingStateDataError: missingStateDataStates.contains(stateID)
                )
            }

            let totalItems = rows.reduce(0) { $0 + $1.totalItems }
            let consumedItems = rows.reduce(0) { partial, row in
                partial + min(row.consumedItems, row.totalItems)
            }

            flowDryFixtureProgress = FlowDryFixtureProgressSummary(
                fixturePath: fixturePath,
                totalItems: totalItems,
                consumedItems: consumedItems,
                rows: rows
            )
            flowDryFixtureProgressError = nil
        } catch {
            flowDryFixtureProgress = nil
            flowDryFixtureProgressError = error.localizedDescription
        }
    }

    private func resolveFixturePathForProgress() -> String? {
        if let activeDryFixturePath {
            return activeDryFixturePath
        }
        guard let run = activeFlowRun,
              run.mode == .dry else {
            return nil
        }
        return flowDryFixturePathByRunID[run.id]
    }

    private func fixtureTotals(at path: String) throws -> [String: Int] {
        let normalized = normalizePath(path)
        if let cached = flowDryFixtureTemplateByPath[normalized] {
            return cached
        }
        let fixture = try FlowDryRunFixture.load(fromPath: normalized)
        let totals = fixture.states.mapValues(\.count)
        flowDryFixtureTemplateByPath[normalized] = totals
        return totals
    }

    private func normalizePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }
        if trimmed.hasPrefix("~/") {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        let baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return URL(fileURLWithPath: trimmed, relativeTo: baseURL).standardizedFileURL.path
    }

    private func clearFlowError() {
        flowLastError = nil
        flowLastErrorCode = nil
        flowLastErrorPhase = nil
        flowLastErrorStateID = nil
        flowLastErrorFieldPath = nil
        flowLastErrorLine = nil
        flowLastErrorColumn = nil
    }

    private func setFlowError(_ error: Error) {
        if let flowError = error as? FlowError {
            flowLastError = flowError.message
            flowLastErrorCode = flowError.code
            flowLastErrorPhase = flowError.phase.rawValue
            flowLastErrorStateID = flowError.stateID
            flowLastErrorFieldPath = flowError.fieldPath
            flowLastErrorLine = flowError.line
            flowLastErrorColumn = flowError.column
        } else {
            flowLastError = error.localizedDescription
            flowLastErrorCode = nil
            flowLastErrorPhase = nil
            flowLastErrorStateID = nil
            flowLastErrorFieldPath = nil
            flowLastErrorLine = nil
            flowLastErrorColumn = nil
        }
    }

    private func decodeJSON<T: Decodable>(_ text: String?) -> T? {
        guard let text,
              let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func updateRunningState() {
        isRunning = !runningScriptIds.isEmpty || !runningAgentScriptIds.isEmpty
    }
}
