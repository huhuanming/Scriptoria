import SwiftUI
import ScriptoriaCore

/// Detail view for a selected script
struct ScriptDetailView: View {
    let script: Script
    @EnvironmentObject var appState: AppState
    @State private var showEditSheet = false
    @State private var runModelOverride = AgentRuntimeCatalog.defaultModel
    @State private var runModelOptions: [String] = [AgentRuntimeCatalog.defaultModel]
    @State private var runtimeSnapshot = AgentRuntimeCatalog.discover()
    @State private var runHistory: [ScriptRun] = []
    @State private var selectedRun: ScriptRun?
    @State private var isAddingTag = false
    @State private var newTagText = ""
    @State private var steerInput = ""
    @State private var agentCommandMode: AgentCommandMode = .prompt
    @State private var averageDuration: TimeInterval?
    @State private var isSummarizingMemory = false
    @State private var selectedAgentTriggerMode: AgentTriggerMode = .always
    @Environment(\.colorScheme) var colorScheme

    var isRunning: Bool {
        appState.runningScriptIds.contains(script.id) || appState.runningAgentScriptIds.contains(script.id)
    }

    var isAgentRunning: Bool {
        appState.runningAgentScriptIds.contains(script.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider().padding(.horizontal, 20)
                infoSection
                Divider().padding(.horizontal, 20)
                ScheduleSection(script: script)
                Divider().padding(.horizontal, 20)
                currentOutputSection
                runHistorySection
            }
        }
        .onChange(of: script.id) { _, _ in
            loadHistory()
            selectedRun = nil
            runModelOverride = AgentRuntimeCatalog.defaultModel
            refreshRunModelOptions()
            selectedAgentTriggerMode = script.agentTriggerMode
            Task { await appState.reloadSchedules() }
        }
        .onChange(of: script.defaultModel) { _, _ in
            refreshRunModelOptions()
        }
        .onChange(of: script.agentTriggerMode) { _, mode in
            selectedAgentTriggerMode = mode
        }
        .onReceive(appState.$scripts) { _ in
            refreshRunModelOptions()
        }
        .onChange(of: appState.currentOutput) { _, _ in
            loadHistory()
        }
        .onAppear {
            loadHistory()
            runModelOverride = AgentRuntimeCatalog.defaultModel
            refreshRunModelOptions()
            selectedAgentTriggerMode = script.agentTriggerMode
            Task { await appState.reloadSchedules() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await appState.toggleFavorite(script) }
                } label: {
                    Image(systemName: script.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(script.isFavorite ? .yellow : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(script.isFavorite ? "Remove from favorites" : "Add to favorites")

                Button { showEditSheet = true } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit script")

                if isRunning {
                    Button {
                        appState.stopScript(script.id)
                    } label: {
                        Image(systemName: "stop.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help("Stop script")
                } else {
                    Button {
                        runWithSelectedModel()
                    } label: {
                        Image(systemName: "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help("Run script")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditScriptSheet(script: script, isPresented: $showEditSheet)
                .environmentObject(appState)
        }
    }

    // MARK: - Header

    var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                // Script icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.accentGradient.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: interpreterIcon)
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(script.title)
                        .font(.title2)
                        .fontWeight(.bold)
                    if !script.description.isEmpty {
                        Text(script.description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 4)

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    // Run/Stop button
                    if isRunning {
                        Button {
                            appState.stopScript(script.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "stop.fill")
                                Text("Stop")
                            }
                        }
                        .buttonStyle(RunButtonStyle(isRunning: isRunning))
                    } else {
                        Button {
                            runWithSelectedModel()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("Run")
                            }
                        }
                        .buttonStyle(RunButtonStyle(isRunning: false))

                        Picker("", selection: $runModelOverride) {
                            ForEach(runModelOptions, id: \.self) { model in
                                Text(modelMenuLabel(for: model)).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(minWidth: 220, alignment: .trailing)
                        .help(modelPickerHelp)
                    }
                }
            }

            // Tags (editable)
            FlowLayout(spacing: 6) {
                ForEach(script.tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        TagCapsule(tag: tag)
                        Button {
                            removeTag(tag)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.tagColor(for: tag).opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if isAddingTag {
                    TextField("tag", text: $newTagText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(width: 80)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.3), in: Capsule())
                        .onSubmit { commitNewTag() }
                        .onExitCommand { isAddingTag = false; newTagText = "" }
                } else {
                    Button {
                        isAddingTag = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(.quaternary.opacity(0.3), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Info

    var infoSection: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 12) {
                StatCard(
                    icon: "play.circle.fill",
                    label: "Total Runs",
                    value: "\(script.runCount)",
                    color: Theme.runningColor
                )

                StatCard(
                    icon: statusIconForCard,
                    label: "Last Status",
                    value: script.lastRunStatus?.rawValue.capitalized ?? "Never",
                    color: lastStatusColor
                )

                StatCard(
                    icon: "clock",
                    label: "Last Run",
                    value: script.lastRunAt?.formatted(.relative(presentation: .named)) ?? "Never",
                    color: .secondary
                )

                StatCard(
                    icon: "timer",
                    label: "Avg Duration",
                    value: averageDuration.map { formatDuration($0) } ?? "—",
                    color: .orange
                )
            }
            .padding(20)

            agentFlowGateSection
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }

    var agentFlowGateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Agent Flow Gate", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            AgentFlowStepRow(
                step: 1,
                title: "Script & Skill Input",
                detail: script.path,
                helper: inputGateHelperText,
                status: inputGateStatus,
                isLast: false
            ) {
                HStack(spacing: 8) {
                    Button {
                        revealInFinder(path: script.path)
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reveal script in Finder")

                    if !normalizedSkillPath.isEmpty {
                        Button {
                            revealInFinder(path: normalizedSkillPath)
                        } label: {
                            Image(systemName: "brain")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reveal skill in Finder")
                    }
                }
            }

            AgentFlowStepRow(
                step: 2,
                title: "Agent Trigger",
                detail: selectedAgentTriggerMode.displayName,
                helper: triggerGateHelperText,
                status: triggerGateStatus,
                isLast: false
            ) {
                Picker("", selection: agentTriggerPickerBinding) {
                    ForEach(AgentTriggerMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 230, alignment: .trailing)
            }

            if selectedAgentTriggerMode == .preScriptTrue {
                agentTriggerBranchesView
                    .padding(.leading, 32)
                    .padding(.bottom, 4)
            }

            AgentFlowStepRow(
                step: 3,
                title: "Task Context",
                detail: taskContextDetailText,
                helper: taskContextHelperText,
                status: taskContextGateStatus,
                isLast: true
            ) {
                Button {
                    isSummarizingMemory = true
                    Task {
                        let _ = await appState.summarizeWorkspaceMemory(for: script)
                        isSummarizingMemory = false
                    }
                } label: {
                    if isSummarizingMemory {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Label("Summarize", systemImage: "doc.text.magnifyingglass")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Summarize task memories into workspace memory")
            }
        }
    }

    // MARK: - Current Output

    var currentOutputSection: some View {
        Group {
            if !appState.currentOutput.isEmpty && appState.currentOutputScriptId == script.id {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(isRunning ? "Running Output" : "Latest Output", systemImage: isRunning ? "play.circle.fill" : "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(isRunning ? Theme.runningColor : Theme.successColor)
                        if let runId = appState.currentRunId, appState.currentOutputScriptId == script.id {
                            Text(String(runId.uuidString.prefix(8)))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.currentOutput, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy output")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    if isAgentRunning {
                        HStack(spacing: 8) {
                            TextField(agentCommandMode == .prompt ? "Guide the running agent..." : "Send /interrupt", text: $steerInput)
                                .textFieldStyle(.roundedBorder)
                                .disabled(agentCommandMode == .interrupt)
                                .onSubmit { sendAgentCommand() }
                            Picker("", selection: $agentCommandMode) {
                                Text("Prompt").tag(AgentCommandMode.prompt)
                                Text("/interrupt").tag(AgentCommandMode.interrupt)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            Button("Send") {
                                sendAgentCommand()
                            }
                            .disabled(agentCommandMode == .prompt && steerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.horizontal, 20)
                    }

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(appState.currentOutput)
                                .terminalOutput()
                            Color.clear.frame(height: 0).id("outputBottom")
                        }
                        .onChange(of: appState.currentOutput) { _, _ in
                            if isRunning {
                                proxy.scrollTo("outputBottom", anchor: .bottom)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 8)
                Divider().padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Run History

    var runHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Run History", systemImage: "clock.arrow.counterclockwise")
                    .font(.headline)
                Spacer()
                if let run = selectedRun ?? runHistory.first {
                    Button {
                        let text = run.output + (run.errorOutput.isEmpty ? "" : "\n--- STDERR ---\n" + run.errorOutput)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy output")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if runHistory.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "text.page")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("Run the script to see history")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                // Run list (horizontal pills)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(runHistory) { run in
                            RunHistoryPill(run: run, isSelected: selectedRun?.id == run.id)
                                .onTapGesture {
                                    withAnimation(Theme.fadeQuick) {
                                        selectedRun = (selectedRun?.id == run.id) ? nil : run
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                // Output for selected (or latest) run
                let displayRun = selectedRun ?? runHistory.first!
                VStack(alignment: .leading, spacing: 6) {
                    // Run detail header
                    HStack(spacing: 12) {
                        runStatusBadge(displayRun.status)
                        if let exitCode = displayRun.exitCode {
                            Text("Exit \(exitCode)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if let duration = displayRun.duration {
                            Text(formatDuration(duration))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(displayRun.startedAt.formatted(Date.FormatStyle()
                            .year().month().day()
                            .hour().minute().second()))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 20)

                    if !displayRun.output.isEmpty || !displayRun.errorOutput.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                if !displayRun.output.isEmpty {
                                    Text(displayRun.output)
                                }
                                if !displayRun.errorOutput.isEmpty {
                                    Text("--- STDERR ---")
                                        .foregroundStyle(Theme.failureColor.opacity(0.7))
                                        .padding(.top, 4)
                                    Text(displayRun.errorOutput)
                                        .foregroundStyle(Theme.failureColor.opacity(0.8))
                                }
                            }
                            .terminalOutput()
                        }
                        .padding(.horizontal, 20)
                    } else {
                        Text("No output")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 20)
                    }
                }
            }
        }
        .padding(.bottom, 20)
    }

    private func loadHistory() {
        runHistory = appState.fetchRunHistory(scriptId: script.id)
        averageDuration = appState.fetchAverageDuration(scriptId: script.id)
    }

    private var normalizedTaskName: String {
        let trimmed = script.agentTaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? script.title : trimmed
    }

    private var normalizedSkillPath: String {
        script.skill.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var inputGateStatus: AgentGateStatus {
        let scriptPath = script.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scriptPath.isEmpty else { return .blocked }
        guard fileExists(atPath: scriptPath) else { return .blocked }
        guard !normalizedSkillPath.isEmpty else { return .ready }
        return fileExists(atPath: normalizedSkillPath) ? .ready : .warning
    }

    private var inputGateHelperText: String {
        if normalizedSkillPath.isEmpty {
            return "No skill file configured. Agent will run with workspace memory only."
        }
        if fileExists(atPath: normalizedSkillPath) {
            return "Skill ready: \(normalizedSkillPath)"
        }
        return "Skill not found: \(normalizedSkillPath). Agent can still run, but without skill injection."
    }

    private var taskContextGateStatus: AgentGateStatus {
        normalizedTaskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .blocked : .ready
    }

    private var taskContextDetailText: String {
        var details: [String] = []
        if let taskId = script.agentTaskId {
            details.append("[\(taskId)] \(normalizedTaskName)")
        } else {
            details.append(normalizedTaskName)
        }
        let model = AgentRuntimeCatalog.normalizeModel(script.defaultModel)
        if !model.isEmpty {
            details.append(model)
        }
        return details.joined(separator: " · ")
    }

    private var taskContextHelperText: String {
        "Task memory namespace is derived from this task name."
    }

    private var latestPreScriptDecision: AgentTriggerDecision? {
        guard let latestSuccess = runHistory.first(where: { $0.status == .success }) else {
            return nil
        }
        return AgentTriggerEvaluator.evaluate(mode: .preScriptTrue, scriptRun: latestSuccess)
    }

    private var triggerGateStatus: AgentGateStatus {
        switch selectedAgentTriggerMode {
        case .always:
            return .ready
        case .preScriptTrue:
            // Conditional gate: this mode branches by script output and is intentionally shown as warning/yellow.
            return .warning
        }
    }

    private var triggerGateHelperText: String {
        switch selectedAgentTriggerMode {
        case .always:
            return selectedAgentTriggerMode.helperText
        case .preScriptTrue:
            switch latestPreScriptDecision {
            case .run:
                return "Conditional gate enabled. Latest successful run resolves to true."
            case .skip:
                return "Conditional gate enabled. Latest successful run resolves to false."
            case .invalid:
                return "Conditional gate enabled. Latest successful run is not parseable yet."
            case nil:
                return "Conditional gate enabled. Waiting for the first successful script output."
            }
        }
    }

    private var agentTriggerBranchesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TriggerBranchCard(
                    branchLabel: "true",
                    actionText: "Run Agent stage",
                    detailText: "Start post-script agent execution",
                    color: Theme.successColor,
                    icon: "checkmark.circle.fill",
                    isHighlighted: isTrueBranchHighlighted
                )
                TriggerBranchCard(
                    branchLabel: "false",
                    actionText: "Skip Agent stage",
                    detailText: "Do not start post-script agent",
                    color: Theme.warningColor,
                    icon: "minus.circle.fill",
                    isHighlighted: isFalseBranchHighlighted
                )
            }

            if case .invalid(let reason) = latestPreScriptDecision {
                Text("Latest parse warning: \(reason)")
                    .font(.caption2)
                    .foregroundStyle(Theme.warningColor.opacity(0.95))
            }
        }
    }

    private var isTrueBranchHighlighted: Bool {
        if case .run = latestPreScriptDecision {
            return true
        }
        return false
    }

    private var isFalseBranchHighlighted: Bool {
        if case .skip = latestPreScriptDecision {
            return true
        }
        return false
    }

    private var agentTriggerPickerBinding: Binding<AgentTriggerMode> {
        Binding(
            get: { selectedAgentTriggerMode },
            set: { newMode in
                selectedAgentTriggerMode = newMode
                updateAgentTriggerMode(newMode)
            }
        )
    }

    private func updateAgentTriggerMode(_ mode: AgentTriggerMode) {
        guard mode != script.agentTriggerMode else { return }
        var updated = script
        updated.agentTriggerMode = mode
        Task {
            await appState.updateScript(updated)
        }
    }

    private func fileExists(atPath path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    private func revealInFinder(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSWorkspace.shared.selectFile(trimmed, inFileViewerRootedAtPath: "")
    }

    private func removeTag(_ tag: String) {
        var updated = script
        updated.tags.removeAll { $0 == tag }
        Task { await appState.updateScript(updated) }
    }

    private func sendAgentCommand() {
        let input = steerInput
        Task {
            await appState.sendAgentCommand(
                scriptId: script.id,
                mode: agentCommandMode,
                input: input
            )
        }
        steerInput = ""
        if agentCommandMode == .interrupt {
            agentCommandMode = .prompt
        }
    }

    private func commitNewTag() {
        let tag = newTagText.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !script.tags.contains(tag) else {
            isAddingTag = false
            newTagText = ""
            return
        }
        var updated = script
        updated.tags.append(tag)
        Task { await appState.updateScript(updated) }
        isAddingTag = false
        newTagText = ""
    }

    private func runWithSelectedModel() {
        Task {
            await appState.runScript(script, modelOverride: runModelOverride)
        }
    }

    private func refreshRunModelOptions() {
        runtimeSnapshot = AgentRuntimeCatalog.discover()

        var options: [String] = []
        appendUniqueModel(into: &options, model: AgentRuntimeCatalog.defaultModel)
        appendUniqueModel(into: &options, model: AgentRuntimeCatalog.normalizeModel(script.defaultModel))
        for model in runtimeSnapshot.models {
            appendUniqueModel(into: &options, model: model)
        }
        for saved in appState.scripts.map(\.defaultModel) {
            appendUniqueModel(into: &options, model: AgentRuntimeCatalog.normalizeModel(saved))
        }

        if options.isEmpty {
            options = [AgentRuntimeCatalog.defaultModel]
        }
        runModelOptions = options

        if let existing = options.first(where: { $0.caseInsensitiveCompare(runModelOverride) == .orderedSame }) {
            runModelOverride = existing
        } else {
            runModelOverride = options[0]
        }
    }

    private func appendUniqueModel(into options: inout [String], model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if options.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        options.append(trimmed)
    }

    private func modelMenuLabel(for model: String) -> String {
        let provider = AgentRuntimeCatalog.provider(forModel: model).displayName
        if model.caseInsensitiveCompare(AgentRuntimeCatalog.defaultModel) == .orderedSame {
            return "\(provider) / GPT-5.3-Codex"
        }
        return "\(provider) / \(model)"
    }

    private var modelPickerHelp: String {
        let configured = runtimeSnapshot.activeProvider
        let providerName = configured?.provider.displayName ?? runtimeSnapshot.configuredProvider.displayName
        let source = configured?.source ?? "default"
        let detected = runtimeSnapshot.providers
            .filter(\.isAvailable)
            .map { $0.provider.displayName }
            .joined(separator: ", ")
        if detected.isEmpty {
            return "Configured provider: \(providerName) (\(source)). No local agent executable detected."
        }
        return "Configured provider: \(providerName) (\(source)). Detected providers: \(detected)."
    }

    private func runStatusBadge(_ status: RunStatus) -> some View {
        let (icon, color, label): (String, Color, String) = switch status {
        case .success: ("checkmark.circle.fill", Theme.successColor, "Success")
        case .failure: ("xmark.circle.fill", Theme.failureColor, "Failed")
        case .running: ("play.circle.fill", Theme.runningColor, "Running")
        case .cancelled: ("stop.circle.fill", Theme.warningColor, "Cancelled")
        }
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m)m \(s)s"
        }
    }

    // MARK: - Helpers

    var interpreterIcon: String {
        switch script.interpreter {
        case .node: return "n.circle"
        case .python, .python3: return "p.circle"
        case .ruby: return "r.circle"
        case .osascript: return "applescript"
        case .bash, .zsh, .sh: return "terminal"
        case .binary: return "gearshape"
        case .auto: return "wand.and.stars"
        }
    }

    var statusIconForCard: String {
        switch script.lastRunStatus {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .running: return "play.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case nil: return "circle.dashed"
        }
    }

    var lastStatusColor: Color {
        switch script.lastRunStatus {
        case .success: return Theme.successColor
        case .failure: return Theme.failureColor
        case .running: return Theme.runningColor
        case .cancelled: return Theme.warningColor
        case nil: return .secondary
        }
    }
}

private enum AgentGateStatus {
    case ready
    case warning
    case blocked

    var color: Color {
        switch self {
        case .ready:
            return Theme.successColor
        case .warning:
            return Theme.warningColor
        case .blocked:
            return Theme.failureColor
        }
    }

    var iconName: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.circle.fill"
        }
    }
}

private struct AgentFlowStepRow<Trailing: View>: View {
    let step: Int
    let title: String
    let detail: String
    let helper: String
    let status: AgentGateStatus
    let isLast: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(status.color.opacity(0.16))
                        .frame(width: 20, height: 20)
                    Image(systemName: status.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(status.color)
                }

                if !isLast {
                    Rectangle()
                        .fill(status.color.opacity(0.45))
                        .frame(width: 2, height: 26)
                        .padding(.top, 4)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(step). \(title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    trailing()
                }

                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if !helper.isEmpty {
                    Text(helper)
                        .font(.caption2)
                        .foregroundStyle(status.color.opacity(0.9))
                        .textSelection(.enabled)
                }
            }
            .padding(.bottom, isLast ? 0 : 6)
        }
    }
}

private struct TriggerBranchCard: View {
    let branchLabel: String
    let actionText: String
    let detailText: String
    let color: Color
    let icon: String
    let isHighlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(branchLabel)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(color)
            }

            Text(actionText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            Text(detailText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(isHighlighted ? 0.18 : 0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(isHighlighted ? 0.8 : 0.4), lineWidth: isHighlighted ? 1.2 : 1)
        )
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Run History Pill

struct RunHistoryPill: View {
    let run: ScriptRun
    let isSelected: Bool

    var statusColor: Color {
        switch run.status {
        case .success: Theme.successColor
        case .failure: Theme.failureColor
        case .running: Theme.runningColor
        case .cancelled: Theme.warningColor
        }
    }

    var statusIcon: String {
        switch run.status {
        case .success: "checkmark"
        case .failure: "xmark"
        case .running: "play.fill"
        case .cancelled: "stop.fill"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: statusIcon)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(statusColor)
            Text(String(run.id.uuidString.prefix(8)))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(isSelected ? .primary : .tertiary)
            Text(run.startedAt.formatted(Date.FormatStyle().hour().minute().second()))
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? statusColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? AnyShapeStyle(statusColor.opacity(0.4)) : AnyShapeStyle(.quaternary.opacity(0.5)), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Group {
                if monospaced {
                    Text(value)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text(value)
                        .font(.body)
                }
            }
            .textSelection(.enabled)
        }
    }
}
