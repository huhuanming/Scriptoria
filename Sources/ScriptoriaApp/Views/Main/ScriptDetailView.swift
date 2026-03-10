import SwiftUI
import ScriptoriaCore

/// Detail view for a selected script
struct ScriptDetailView: View {
    let script: Script
    @EnvironmentObject var appState: AppState
    @State private var showEditSheet = false
    @State private var showRunSheet = false
    @State private var runModelOverride = ""
    @State private var runHistory: [ScriptRun] = []
    @State private var selectedRun: ScriptRun?
    @State private var isAddingTag = false
    @State private var newTagText = ""
    @State private var steerInput = ""
    @State private var agentCommandMode: AgentCommandMode = .prompt
    @State private var averageDuration: TimeInterval?
    @State private var isSummarizingMemory = false
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
            runModelOverride = script.defaultModel
            Task { await appState.reloadSchedules() }
        }
        .onChange(of: appState.currentOutput) { _, _ in
            loadHistory()
        }
        .onAppear {
            loadHistory()
            runModelOverride = script.defaultModel
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
                        runModelOverride = script.defaultModel
                        showRunSheet = true
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
        .sheet(isPresented: $showRunSheet) {
            RunWithModelSheet(
                scriptTitle: script.title,
                defaultModel: script.defaultModel,
                modelOverride: $runModelOverride,
                isPresented: $showRunSheet
            ) { model in
                Task {
                    await appState.runScript(script, modelOverride: model)
                }
            }
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
                        runModelOverride = script.defaultModel
                        showRunSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Run")
                        }
                    }
                    .buttonStyle(RunButtonStyle(isRunning: false))
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

            // Path
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(script.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSWorkspace.shared.selectFile(script.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, script.skill.isEmpty ? 16 : 8)

            // Skill
            if !script.skill.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(script.skill)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSWorkspace.shared.selectFile(script.skill, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "arrow.right.circle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            HStack(spacing: 8) {
                Image(systemName: "target")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let taskId = script.agentTaskId {
                    Text("[\(taskId)] \(script.agentTaskName)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(script.agentTaskName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !script.defaultModel.isEmpty {
                    Text("· \(script.defaultModel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
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
                        Label("Summarize Workspace", systemImage: "doc.text.magnifyingglass")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Summarize task memories into workspace memory")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
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

struct RunWithModelSheet: View {
    let scriptTitle: String
    let defaultModel: String
    @Binding var modelOverride: String
    @Binding var isPresented: Bool
    let onRun: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run Script")
                .font(.headline)
            Text(scriptTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Model (leave blank to use default)", text: $modelOverride)
                .textFieldStyle(.roundedBorder)

            if !defaultModel.isEmpty {
                Text("Default: \(defaultModel)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Run") {
                    let value = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
                    onRun(value.isEmpty ? nil : value)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
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
