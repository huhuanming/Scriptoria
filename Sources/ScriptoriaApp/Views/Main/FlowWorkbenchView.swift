import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ScriptoriaCore

struct FlowListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(
            appState.flowDefinitions,
            id: \.definition.id,
            selection: Binding(
                get: { appState.selectedFlowDefinitionID },
                set: { newValue in
                    appState.selectedFlowDefinitionID = newValue
                    Task { await appState.selectFlowDefinition(newValue) }
                }
            )
        ) { summary in
            FlowListRow(summary: summary)
                .tag(summary.definition.id)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importFlows()
                } label: {
                    Label("Import Flow", systemImage: "square.and.arrow.down")
                }
            }
        }
        .overlay {
            if appState.flowDefinitions.isEmpty {
                ContentUnavailableView {
                    Label("No Flows", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Import a flow.yaml to start validate/compile/run/dry-run in GUI.")
                } actions: {
                    Button("Import Flow") { importFlows() }
                }
            }
        }
    }

    private func importFlows() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.yaml, .init(filenameExtension: "yml")].compactMap { $0 }
        if panel.runModal() == .OK {
            for url in panel.urls {
                Task {
                    await appState.importFlowDefinition(at: url.path)
                }
            }
        }
    }
}

private struct FlowListRow: View {
    let summary: FlowDefinitionStatusSummary

    private var statusColor: Color {
        switch summary.latestRunStatus {
        case .success:
            return .green
        case .failure:
            return .red
        case .running:
            return .orange
        case nil:
            return .secondary
        }
    }

    private var statusText: String {
        switch summary.latestRunStatus {
        case .success:
            return "Success"
        case .failure:
            return "Failure"
        case .running:
            return "Running"
        case nil:
            return "Never Run"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor.opacity(0.18))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.definition.name)
                    .fontWeight(.medium)
                Text(summary.definition.displayFlowPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = summary.latestErrorCode, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if let latestRunAt = summary.latestRunAt {
                    Text(latestRunAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let steps = summary.latestSteps {
                    Text("\(steps) steps")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct FlowDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case validateCompile = "Validate/Compile"
        case run = "Run"
        case dryRun = "Dry-Run"
        case history = "History"
        case diagnostics = "Diagnostics"

        var id: String { rawValue }
    }

    @EnvironmentObject var appState: AppState

    @State private var selectedTab: Tab = .overview
    @State private var noFSCheck = false
    @State private var compileOutputPath = ""
    @State private var contextOverridesText = ""
    @State private var maxRoundsText = ""
    @State private var initialCommandsText = ""
    @State private var liveCommandText = ""
    @State private var dryFixturePath = ""

    private var selectedSummary: FlowDefinitionStatusSummary? {
        appState.selectedFlowDefinition
    }

    private var traversedEdgeIDs: Set<String> {
        Set(appState.activeFlowSteps.compactMap { step in
            guard let transition = step.transition else { return nil }
            return "\(step.stateID)->\(transition)"
        })
    }

    private var currentGraphStateID: String? {
        appState.activeFlowSteps.last?.stateID ?? appState.activeFlowRun?.endedAtState
    }

    var body: some View {
        Group {
            if let summary = selectedSummary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(summary: summary)
                        Picker("Tab", selection: $selectedTab) {
                            ForEach(Tab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch selectedTab {
                        case .overview:
                            overviewPanel(summary: summary)
                        case .validateCompile:
                            validateCompilePanel(summary: summary)
                        case .run:
                            runPanel(summary: summary)
                        case .dryRun:
                            dryRunPanel(summary: summary)
                        case .history:
                            historyPanel()
                        case .diagnostics:
                            diagnosticsPanel()
                        }
                    }
                    .padding(20)
                }
                .onAppear {
                    if compileOutputPath.isEmpty {
                        let base = summary.definition.workspacePath
                        let name = summary.definition.name
                        compileOutputPath = "\(base)/compiled/\(name).flow.ir.json"
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Flow Selected", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Pick a flow from the list to open Flow Workbench.")
                }
            }
        }
    }

    @ViewBuilder
    private func header(summary: FlowDefinitionStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.definition.name)
                .font(.title2.weight(.bold))
            Text(summary.definition.canonicalFlowPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if appState.flowWorkbenchMode == .diagnosticsOnly {
                Text("Flow workbench is currently in diagnostics-only mode. Running new flows is disabled.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = appState.flowLastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func overviewPanel(summary: FlowDefinitionStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Workspace", value: summary.definition.workspacePath)
                LabeledContent("Latest Status", value: summary.latestRunStatus?.rawValue.capitalized ?? "Never Run")
                LabeledContent("Latest Error", value: summary.latestErrorCode ?? "—")
                LabeledContent("Latest Run", value: summary.latestRunAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                if let run = appState.activeFlowRun {
                    LabeledContent("Active Run ID", value: run.id.uuidString.lowercased())
                    LabeledContent("Commands", value: "\(run.commandsConsumed)/\(run.commandsQueued) consumed")
                    if run.commandEventsTruncated {
                        Text("Command events truncated \(run.commandEventsTruncatedCount) times.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            GroupBox("State Graph") {
                if appState.flowGraphNodes.isEmpty {
                    Text("No graph data. Validate/Compile to refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.flowGraphNodes) { node in
                            stateGraphNodeRow(node: node)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stateGraphNodeRow(node: FlowGraphNodeRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if node.isStart {
                    Text("start")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.teal.opacity(0.16), in: Capsule())
                }
                Text(node.stateID)
                    .font(.caption.weight(.semibold))
                Text(node.stateType)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(stateTypeColor(node.stateType).opacity(0.16), in: Capsule())
                Spacer()
                if currentGraphStateID == node.stateID {
                    Text("active")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                }
            }

            if node.outgoing.isEmpty {
                Text("no outgoing edges")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(node.outgoing) { edge in
                    let edgeKey = "\(edge.fromStateID)->\(edge.toStateID)"
                    let isTraversed = traversedEdgeIDs.contains(edgeKey)
                    HStack(spacing: 6) {
                        Image(systemName: isTraversed ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundStyle(isTraversed ? Color.green : Color.secondary)
                        Text("\(edge.label) -> \(edge.toStateID)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            (currentGraphStateID == node.stateID ? Color.orange.opacity(0.12) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    @ViewBuilder
    private func validateCompilePanel(summary: FlowDefinitionStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("No filesystem check", isOn: $noFSCheck)

            HStack(spacing: 10) {
                Button("Validate") {
                    Task { await appState.validateSelectedFlow(noFSCheck: noFSCheck) }
                }
                .buttonStyle(.borderedProminent)

                Button("Compile") {
                    Task {
                        await appState.compileSelectedFlow(
                            outputPath: compileOutputPath,
                            noFSCheck: noFSCheck
                        )
                    }
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                TextField("Compile output path", text: $compileOutputPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.json]
                    panel.nameFieldStringValue = "\(summary.definition.name).flow.ir.json"
                    if panel.runModal() == .OK {
                        compileOutputPath = panel.url?.path ?? compileOutputPath
                    }
                }
            }

            if let outputPath = appState.flowLastCompileOutputPath {
                Text("Last Output: \(outputPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if appState.flowLastCompileCleanupCount > 0 {
                Text("Cleanup removed \(appState.flowLastCompileCleanupCount) old compile artifact(s).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !appState.flowLastCompilePreview.isEmpty {
                GroupBox("IR Preview") {
                    ScrollView {
                        Text(appState.flowLastCompilePreview)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 160)
                    .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private func runPanel(summary _: FlowDefinitionStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Run Options") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Context Overrides (one per line: key=value)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $contextOverridesText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80)

                    HStack(spacing: 8) {
                        TextField("max-agent-rounds", text: $maxRoundsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Spacer()
                    }

                    Text("Initial Commands (one per line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $initialCommandsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 70)
                }
                .padding(8)
            }

            HStack(spacing: 10) {
                Button(appState.isFlowRunning ? "Running..." : "Run Live") {
                    Task {
                        await appState.runSelectedFlowLive(
                            contextOverrides: parseContextOverrides(contextOverridesText),
                            maxAgentRounds: Int(maxRoundsText),
                            initialCommands: parseMultiline(initialCommandsText)
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isFlowRunning || appState.flowWorkbenchMode == .diagnosticsOnly)

                Button("Interrupt") {
                    appState.interruptFlowRun()
                }
                .buttonStyle(.bordered)
                .disabled(!appState.isFlowRunning)
            }

            HStack(spacing: 8) {
                TextField("Send steer/interrupt command", text: $liveCommandText)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    appState.sendFlowCommand(liveCommandText)
                    liveCommandText = ""
                }
                .disabled(!appState.isFlowRunning)
            }

            GroupBox("Step Timeline") {
                if appState.activeFlowSteps.isEmpty {
                    Text("No step events yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.activeFlowSteps, id: \.seq) { step in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                Text("#\(step.seq)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(step.stateID)
                                    .font(.caption.weight(.semibold))
                                Text(step.phase.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let transition = step.transition {
                                    Text("-> \(transition)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let error = step.error {
                                    Text(error.code)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                                Spacer()
                                if let duration = step.duration {
                                    Text(String(format: "%.3fs", duration))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                                if let counter = step.counter {
                                    Text("counter=\(counter.name) value=\(counter.value) max=\(counter.effectiveMax)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if let contextDelta = step.contextDelta, !contextDelta.isEmpty {
                                    Text("context delta keys: \(contextDelta.keys.sorted().joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private func dryRunPanel(summary _: FlowDefinitionStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Dry-run fixture path", text: $dryFixturePath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK {
                        dryFixturePath = panel.url?.path ?? dryFixturePath
                    }
                }
            }

            Button(appState.isFlowRunning ? "Running..." : "Run Dry-Run") {
                Task {
                    await appState.runSelectedFlowDry(fixturePath: dryFixturePath)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isFlowRunning || dryFixturePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.flowWorkbenchMode == .diagnosticsOnly)

            GroupBox("Fixture Consumption") {
                if let error = appState.flowDryFixtureProgressError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else if let progress = appState.flowDryFixtureProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(progress.fixturePath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack(spacing: 14) {
                            Text("total \(progress.totalItems)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("consumed \(progress.consumedItems)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                            Text("remaining \(progress.remainingItems)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(progress.remainingItems == 0 ? Color.secondary : Color.orange)
                        }

                        if progress.rows.isEmpty {
                            Text("No fixture state entries.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(progress.rows) { row in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(row.stateID)
                                                .font(.caption.weight(.semibold))
                                            if let stateType = row.stateType {
                                                Text(stateType)
                                                    .font(.caption2.monospaced())
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text("\(row.consumedItems)/\(row.totalItems)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(fixtureStatusLabel(row))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(fixtureStatusColor(row))
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } else {
                    Text("Run a dry-run to see fixture consumption progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private func historyPanel() -> some View {
        if appState.flowRunHistory.isEmpty {
            Text("No history yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(appState.flowRunHistory) { run in
                    HStack {
                        Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.monospacedDigit())
                        Text(run.mode.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(run.status.rawValue)
                            .font(.caption2)
                            .foregroundStyle(run.status == .success ? .green : .red)
                        if let errorCode = run.errorCode {
                            Text(errorCode)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Text("\(run.steps) steps")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        (appState.activeFlowRun?.id == run.id ? Color.accentColor.opacity(0.12) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .onTapGesture {
                        appState.selectFlowRun(run)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticsPanel() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Error Detail") {
                if let code = appState.flowLastErrorCode {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("code: \(code)")
                            .font(.caption.monospaced())
                        if let phase = appState.flowLastErrorPhase {
                            Text("phase: \(phase)")
                                .font(.caption.monospaced())
                        }
                        if let stateID = appState.flowLastErrorStateID {
                            Text("state_id: \(stateID)")
                                .font(.caption.monospaced())
                        }
                        if let fieldPath = appState.flowLastErrorFieldPath {
                            Text("field_path: \(fieldPath)")
                                .font(.caption.monospaced())
                        }
                        if let line = appState.flowLastErrorLine {
                            let column = appState.flowLastErrorColumn ?? 0
                            Text("line: \(line) column: \(column)")
                                .font(.caption.monospaced())
                        }
                        if let message = appState.flowLastError {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } else {
                    Text("No active error.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }

            GroupBox("Warnings") {
                if appState.activeFlowWarnings.isEmpty {
                    Text("No warnings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(appState.activeFlowWarnings.enumerated()), id: \.offset) { _, warning in
                            Text("[\(warning.scope.rawValue)] \(warning.code): \(warning.message)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }

            GroupBox("Command Queue") {
                if appState.activeFlowCommandEvents.isEmpty {
                    Text("No command queue events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.activeFlowCommandEvents, id: \.seq) { event in
                            Text("#\(event.seq) \(uiActionLabel(event.action)) q=\(event.queueDepth) \(event.commandPreview)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }

            GroupBox("Raw Logs") {
                ScrollView {
                    Text(appState.flowCurrentLog.isEmpty ? "(empty)" : appState.flowCurrentLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180)
                .padding(8)
            }
        }
    }

    private func uiActionLabel(_ action: FlowCommandQueueAction) -> String {
        switch action {
        case .rejectedRetry:
            return "retried"
        default:
            return action.rawValue
        }
    }

    private func stateTypeColor(_ stateType: String) -> Color {
        switch stateType {
        case "gate":
            return .blue
        case "agent":
            return .orange
        case "script":
            return .green
        case "wait":
            return .purple
        case "end":
            return .gray
        default:
            return .secondary
        }
    }

    private func fixtureStatusLabel(_ row: FlowDryFixtureStateProgressRow) -> String {
        if row.isUnknownState {
            return "unknown"
        }
        if row.hasMissingStateDataError {
            return "missing"
        }
        if row.hasUnconsumedItemsError {
            return "unconsumed"
        }
        if row.hasUnusedStateWarning {
            return "unused"
        }
        if row.totalItems == 0 {
            return "empty"
        }
        if row.remainingItems == 0 {
            return "complete"
        }
        if row.consumedItems > 0 {
            return "partial"
        }
        return "pending"
    }

    private func fixtureStatusColor(_ row: FlowDryFixtureStateProgressRow) -> Color {
        if row.isUnknownState || row.hasMissingStateDataError || row.hasUnconsumedItemsError {
            return .red
        }
        if row.hasUnusedStateWarning {
            return .orange
        }
        if row.remainingItems == 0 && row.totalItems > 0 {
            return .green
        }
        return .secondary
    }

    private func parseContextOverrides(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let content = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let parts = content.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private func parseMultiline(_ raw: String) -> [String] {
        raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
