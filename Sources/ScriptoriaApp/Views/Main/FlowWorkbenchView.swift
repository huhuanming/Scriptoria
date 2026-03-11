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

private struct FlowEditorPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

private struct FlowEditorLayoutFile: Codable, Equatable {
    var version: Int
    var nodes: [String: FlowEditorPoint]

    init(version: Int = 1, nodes: [String: FlowEditorPoint]) {
        self.version = version
        self.nodes = nodes
    }
}

private struct FlowEditorNodeDraft: Identifiable, Equatable {
    var id: String { state.id }
    var state: FlowStateDefinition
    var center: CGPoint
}

private struct FlowEditorDraft: Equatable {
    var definitionID: UUID
    var flowPath: String
    var version: String
    var start: String
    var defaults: FlowDefaults
    var context: [String: FlowValue]
    var nodes: [FlowEditorNodeDraft]
    var selectedNodeID: String?
    var isDirty: Bool
}

private struct FlowEditorCanvasEdge: Identifiable, Equatable {
    var id: String {
        "\(fromID)->\(label)->\(toID)"
    }

    var fromID: String
    var toID: String
    var label: String
    var isBroken: Bool
}

struct FlowDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case editor = "Editor"
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
    @State private var editorDraft: FlowEditorDraft?
    @State private var editorHistory: [FlowEditorDraft] = []
    @State private var editorHistoryIndex: Int = -1
    @State private var editorInfoMessage: String?
    @State private var editorErrorMessage: String?
    @State private var dragBaseCenters: [String: CGPoint] = [:]

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
                        case .editor:
                            editorPanel(summary: summary)
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
                    if editorDraft?.definitionID != summary.definition.id {
                        loadEditorDraft(for: summary)
                    }
                }
                .onChange(of: summary.definition.id) {
                    loadEditorDraft(for: summary)
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
    private func editorPanel(summary: FlowDefinitionStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Menu("Add Node") {
                    Button("Gate") { addEditorNode(type: .gate) }
                    Button("Agent") { addEditorNode(type: .agent) }
                    Button("Wait") { addEditorNode(type: .wait) }
                    Button("Script") { addEditorNode(type: .script) }
                    Button("End") { addEditorNode(type: .end) }
                }
                .disabled(editorDraft == nil)

                Button("Delete Node") {
                    deleteSelectedEditorNode()
                }
                .disabled(selectedEditorNode == nil)

                Button("Auto Layout") {
                    autoLayoutEditorNodes()
                }
                .disabled(editorDraft == nil)

                Spacer()

                Button("Undo") {
                    undoEditor()
                }
                .disabled(editorHistoryIndex <= 0)

                Button("Redo") {
                    redoEditor()
                }
                .disabled(editorHistoryIndex < 0 || editorHistoryIndex >= editorHistory.count - 1)

                Button("Revert") {
                    loadEditorDraft(for: summary)
                }
                .disabled(!(editorDraft?.isDirty ?? false))

                Button("Validate Draft") {
                    validateEditorDraft()
                }
                .disabled(editorDraft == nil)

                Button("Save") {
                    Task { await saveEditorDraft() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(editorDraft == nil || !(editorDraft?.isDirty ?? false))
            }

            if let message = editorInfoMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let error = editorErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let draft = editorDraft, draft.definitionID == summary.definition.id {
                HSplitView {
                    editorCanvas(draft: draft)
                    editorInspector(draft: draft)
                        .frame(minWidth: 330, idealWidth: 360, maxWidth: 440)
                }
                .frame(minHeight: 520)
            } else {
                Text("Loading editor draft...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func editorCanvas(draft: FlowEditorDraft) -> some View {
        let canvasSize = editorCanvasSize(for: draft)
        let nodeCenters = Dictionary(uniqueKeysWithValues: draft.nodes.map { ($0.id, $0.center) })
        let edges = editorEdges(for: draft)

        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: canvasSize.width, height: canvasSize.height)

                ForEach(edges) { edge in
                    editorEdgeView(edge: edge, nodeCenters: nodeCenters)
                }

                ForEach(draft.nodes) { node in
                    editorNodeCard(node: node, isSelected: node.id == draft.selectedNodeID)
                        .position(node.center)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func editorEdgeView(edge: FlowEditorCanvasEdge, nodeCenters: [String: CGPoint]) -> some View {
        let from = nodeCenters[edge.fromID] ?? .zero
        let to = nodeCenters[edge.toID] ?? CGPoint(x: from.x + 180, y: from.y)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let strokeColor: Color = edge.isBroken ? .red : .secondary
        let dash: [CGFloat] = edge.isBroken ? [6, 5] : []

        Path { path in
            path.move(to: from)
            let control1 = CGPoint(x: from.x + 65, y: from.y)
            let control2 = CGPoint(x: to.x - 65, y: to.y)
            path.addCurve(to: to, control1: control1, control2: control2)
        }
        .stroke(strokeColor.opacity(0.75), style: StrokeStyle(lineWidth: 1.8, dash: dash))

        Text(edge.label)
            .font(.caption2.monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(nsColor: .textBackgroundColor), in: Capsule())
            .foregroundStyle(strokeColor)
            .position(mid)
    }

    @ViewBuilder
    private func editorNodeCard(node: FlowEditorNodeDraft, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(node.state.id)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(node.state.type.rawValue)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(stateTypeColor(node.state.type.rawValue).opacity(0.15), in: Capsule())
            }
            Text(editorNodeSummary(node.state))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .frame(width: 200, height: 94)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
        .onTapGesture {
            selectEditorNode(node.id)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    handleNodeDragChanged(nodeID: node.id, translation: value.translation)
                }
                .onEnded { value in
                    handleNodeDragEnded(nodeID: node.id, translation: value.translation)
                }
        )
    }

    @ViewBuilder
    private func editorInspector(draft: FlowEditorDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Flow") {
                    VStack(alignment: .leading, spacing: 10) {
                        targetPicker(
                            title: "start",
                            selection: draft.start,
                            candidates: draft.nodes.map(\.id),
                            required: true
                        ) { value in
                            guard let value else { return }
                            mutateEditorDraft { edited in
                                edited.start = value
                            }
                        }

                        Stepper(value: Binding(
                            get: { draft.defaults.maxAgentRounds },
                            set: { value in
                                mutateEditorDraft { edited in
                                    edited.defaults.maxAgentRounds = max(value, 1)
                                }
                            }
                        ), in: 1...10000) {
                            Text("max_agent_rounds: \(draft.defaults.maxAgentRounds)")
                                .font(.caption.monospacedDigit())
                        }

                        Stepper(value: Binding(
                            get: { draft.defaults.maxWaitCycles },
                            set: { value in
                                mutateEditorDraft { edited in
                                    edited.defaults.maxWaitCycles = max(value, 1)
                                }
                            }
                        ), in: 1...100000) {
                            Text("max_wait_cycles: \(draft.defaults.maxWaitCycles)")
                                .font(.caption.monospacedDigit())
                        }

                        Stepper(value: Binding(
                            get: { draft.defaults.maxTotalSteps },
                            set: { value in
                                mutateEditorDraft { edited in
                                    edited.defaults.maxTotalSteps = max(value, 1)
                                }
                            }
                        ), in: 1...100000) {
                            Text("max_total_steps: \(draft.defaults.maxTotalSteps)")
                                .font(.caption.monospacedDigit())
                        }

                        Stepper(value: Binding(
                            get: { draft.defaults.stepTimeoutSec },
                            set: { value in
                                mutateEditorDraft { edited in
                                    edited.defaults.stepTimeoutSec = max(value, 1)
                                }
                            }
                        ), in: 1...100000) {
                            Text("step_timeout_sec: \(draft.defaults.stepTimeoutSec)")
                                .font(.caption.monospacedDigit())
                        }

                        Toggle("fail_on_parse_error", isOn: Binding(
                            get: { draft.defaults.failOnParseError },
                            set: { value in
                                mutateEditorDraft { edited in
                                    edited.defaults.failOnParseError = value
                                }
                            }
                        ))
                        .font(.caption)
                    }
                    .padding(8)
                }

                GroupBox("Node") {
                    if let node = selectedEditorNode {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(node.state.id)
                                .font(.caption.weight(.semibold))
                            Text(node.state.type.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            selectedNodeInspectorFields(node: node, candidates: draft.nodes.map(\.id))
                        }
                        .padding(8)
                    } else {
                        Text("Select a node from canvas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func selectedNodeInspectorFields(node: FlowEditorNodeDraft, candidates: [String]) -> some View {
        switch node.state.type {
        case .gate:
            TextField("run", text: Binding(
                get: { selectedEditorNode?.state.run ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.run = normalizedOptional(value)
                    }
                }
            ))
            targetPicker(title: "on.pass", selection: node.state.on?.pass, candidates: candidates, required: true) { value in
                updateSelectedNodeState { state in
                    var transitions = state.on ?? FlowGateTransitions(pass: "", needsAgent: "", wait: "", fail: "")
                    transitions.pass = value ?? state.id
                    state.on = transitions
                }
            }
            targetPicker(title: "on.needs_agent", selection: node.state.on?.needsAgent, candidates: candidates, required: true) { value in
                updateSelectedNodeState { state in
                    var transitions = state.on ?? FlowGateTransitions(pass: "", needsAgent: "", wait: "", fail: "")
                    transitions.needsAgent = value ?? state.id
                    state.on = transitions
                }
            }
            targetPicker(title: "on.wait", selection: node.state.on?.wait, candidates: candidates, required: true) { value in
                updateSelectedNodeState { state in
                    var transitions = state.on ?? FlowGateTransitions(pass: "", needsAgent: "", wait: "", fail: "")
                    transitions.wait = value ?? state.id
                    state.on = transitions
                }
            }
            targetPicker(title: "on.fail", selection: node.state.on?.fail, candidates: candidates, required: true) { value in
                updateSelectedNodeState { state in
                    var transitions = state.on ?? FlowGateTransitions(pass: "", needsAgent: "", wait: "", fail: "")
                    transitions.fail = value ?? state.id
                    state.on = transitions
                }
            }
            targetPicker(title: "on.parse_error", selection: node.state.on?.parseError, candidates: candidates, required: false) { value in
                updateSelectedNodeState { state in
                    var transitions = state.on ?? FlowGateTransitions(pass: "", needsAgent: "", wait: "", fail: "")
                    transitions.parseError = value
                    state.on = transitions
                }
            }
        case .agent:
            TextField("task", text: Binding(
                get: { selectedEditorNode?.state.task ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.task = normalizedOptional(value)
                    }
                }
            ))
            TextField("model", text: Binding(
                get: { selectedEditorNode?.state.model ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.model = normalizedOptional(value)
                    }
                }
            ))
            TextField("counter", text: Binding(
                get: { selectedEditorNode?.state.counter ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.counter = normalizedOptional(value)
                    }
                }
            ))
            TextField("max_rounds", text: Binding(
                get: { selectedEditorNode?.state.maxRounds.map(String.init) ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.maxRounds = Int(value)
                    }
                }
            ))
            TextField("prompt", text: Binding(
                get: { selectedEditorNode?.state.prompt ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.prompt = normalizedOptional(value)
                    }
                }
            ))
            targetPicker(title: "next", selection: node.state.next, candidates: candidates, required: true) { value in
                updateSelectedNodeState { state in
                    state.next = value
                }
            }
        case .wait:
            targetPicker(title: "next", selection: node.state.next, candidates: candidates, required: true) { value in
                updateSelectedNodeState { state in
                    state.next = value
                }
            }
            TextField("seconds", text: Binding(
                get: { selectedEditorNode?.state.seconds.map(String.init) ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.seconds = Int(value)
                    }
                }
            ))
            TextField("seconds_from", text: Binding(
                get: { selectedEditorNode?.state.secondsFrom ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.secondsFrom = normalizedOptional(value)
                    }
                }
            ))
        case .script:
            TextField("run", text: Binding(
                get: { selectedEditorNode?.state.run ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.run = normalizedOptional(value)
                    }
                }
            ))
            targetPicker(title: "next", selection: node.state.next, candidates: candidates, required: true) { value in
                updateSelectedNodeState { state in
                    state.next = value
                }
            }
        case .end:
            Picker("status", selection: Binding(
                get: { selectedEditorNode?.state.endStatus ?? .success },
                set: { value in
                    updateSelectedNodeState { state in
                        state.endStatus = value
                    }
                }
            )) {
                Text("success").tag(FlowEndStatus.success)
                Text("failure").tag(FlowEndStatus.failure)
            }
            .pickerStyle(.segmented)

            TextField("message", text: Binding(
                get: { selectedEditorNode?.state.message ?? "" },
                set: { value in
                    updateSelectedNodeState { state in
                        state.message = normalizedOptional(value)
                    }
                }
            ))
        }
    }

    @ViewBuilder
    private func targetPicker(
        title: String,
        selection: String?,
        candidates: [String],
        required: Bool,
        onChange: @escaping (String?) -> Void
    ) -> some View {
        let noneTag = "__none__"
        Picker(title, selection: Binding(
            get: {
                selection ?? noneTag
            },
            set: { raw in
                if raw == noneTag {
                    onChange(required ? candidates.first : nil)
                } else {
                    onChange(raw)
                }
            }
        )) {
            if !required {
                Text("—").tag(noneTag)
            }
            ForEach(candidates, id: \.self) { id in
                Text(id).tag(id)
            }
        }
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

    private var selectedEditorNodeIndex: Int? {
        guard let draft = editorDraft,
              let selectedNodeID = draft.selectedNodeID else {
            return nil
        }
        return draft.nodes.firstIndex { $0.id == selectedNodeID }
    }

    private var selectedEditorNode: FlowEditorNodeDraft? {
        guard let draft = editorDraft,
              let index = selectedEditorNodeIndex,
              draft.nodes.indices.contains(index) else {
            return nil
        }
        return draft.nodes[index]
    }

    private func loadEditorDraft(for summary: FlowDefinitionStatusSummary) {
        do {
            let definition = try FlowYAMLEditorCodec.loadDefinition(
                atPath: summary.definition.canonicalFlowPath,
                noFSCheck: true
            )
            let layout = loadEditorLayout(forFlowPath: summary.definition.canonicalFlowPath)
            let centers = layout ?? autoLayoutCenters(for: definition)
            let nodes = definition.states.map { state in
                let center = centers[state.id] ?? CGPoint(x: 160, y: 120)
                return FlowEditorNodeDraft(state: state, center: center)
            }

            let selectedID = nodes.first(where: { $0.id == definition.start })?.id ?? nodes.first?.id
            let draft = FlowEditorDraft(
                definitionID: summary.definition.id,
                flowPath: summary.definition.canonicalFlowPath,
                version: definition.version,
                start: definition.start,
                defaults: definition.defaults,
                context: definition.context,
                nodes: nodes,
                selectedNodeID: selectedID,
                isDirty: false
            )
            editorDraft = draft
            resetEditorHistory(with: draft)
            editorInfoMessage = nil
            editorErrorMessage = nil
            dragBaseCenters = [:]
        } catch {
            editorDraft = nil
            editorHistory = []
            editorHistoryIndex = -1
            editorErrorMessage = "Failed to load editor draft: \(error.localizedDescription)"
        }
    }

    private func resetEditorHistory(with draft: FlowEditorDraft) {
        editorHistory = [draft]
        editorHistoryIndex = 0
    }

    private func pushEditorHistory(_ draft: FlowEditorDraft) {
        let safeIndex = max(0, min(editorHistoryIndex, editorHistory.count - 1))
        let base = editorHistory.isEmpty ? [] : Array(editorHistory.prefix(safeIndex + 1))
        if base.last == draft {
            return
        }
        editorHistory = base + [draft]
        editorHistoryIndex = editorHistory.count - 1
    }

    private func mutateEditorDraft(
        pushHistory: Bool = true,
        markDirty: Bool = true,
        _ mutation: (inout FlowEditorDraft) -> Void
    ) {
        guard var draft = editorDraft else { return }
        let before = draft
        mutation(&draft)
        guard draft != before else { return }
        if markDirty {
            draft.isDirty = true
        }
        editorDraft = draft
        if pushHistory {
            pushEditorHistory(draft)
        }
    }

    private func selectEditorNode(_ nodeID: String) {
        mutateEditorDraft(pushHistory: false, markDirty: false) { draft in
            draft.selectedNodeID = nodeID
        }
    }

    private func updateSelectedNodeState(_ mutation: (inout FlowStateDefinition) -> Void) {
        mutateEditorDraft { draft in
            guard let selectedNodeID = draft.selectedNodeID,
                  let index = draft.nodes.firstIndex(where: { $0.id == selectedNodeID }) else {
                return
            }
            mutation(&draft.nodes[index].state)
        }
    }

    private func addEditorNode(type: FlowStateType) {
        mutateEditorDraft { draft in
            let existingIDs = Set(draft.nodes.map(\.id))
            let newID = nextEditorStateID(base: type.rawValue, existingIDs: existingIDs)
            let fallbackTarget = draft.start.isEmpty ? draft.nodes.first?.id : draft.start
            let state = defaultState(
                type: type,
                id: newID,
                fallbackTarget: fallbackTarget
            )
            let maxX = draft.nodes.map { $0.center.x }.max() ?? 120
            let ySeed = draft.nodes.count % 5
            let center = CGPoint(x: maxX + 250, y: 120 + CGFloat(ySeed) * 140)
            draft.nodes.append(FlowEditorNodeDraft(state: state, center: center))
            draft.selectedNodeID = newID
            if draft.start.isEmpty {
                draft.start = newID
            }
        }
    }

    private func deleteSelectedEditorNode() {
        guard let selectedNode = selectedEditorNode else { return }
        guard let draft = editorDraft, draft.nodes.count > 1 else {
            editorErrorMessage = "Flow must contain at least one state."
            return
        }

        mutateEditorDraft { edited in
            guard let removeIndex = edited.nodes.firstIndex(where: { $0.id == selectedNode.id }) else {
                return
            }
            edited.nodes.remove(at: removeIndex)
            let replacementID = edited.nodes.first?.id ?? ""
            if edited.start == selectedNode.id {
                edited.start = replacementID
            }
            for index in edited.nodes.indices {
                if edited.nodes[index].state.next == selectedNode.id {
                    edited.nodes[index].state.next = replacementID
                }
                if var on = edited.nodes[index].state.on {
                    if on.pass == selectedNode.id { on.pass = replacementID }
                    if on.needsAgent == selectedNode.id { on.needsAgent = replacementID }
                    if on.wait == selectedNode.id { on.wait = replacementID }
                    if on.fail == selectedNode.id { on.fail = replacementID }
                    if on.parseError == selectedNode.id { on.parseError = replacementID }
                    edited.nodes[index].state.on = on
                }
            }
            edited.selectedNodeID = replacementID
        }
    }

    private func autoLayoutEditorNodes() {
        mutateEditorDraft { draft in
            let definition = flowDefinition(from: draft)
            let centers = autoLayoutCenters(for: definition)
            for index in draft.nodes.indices {
                let id = draft.nodes[index].id
                if let center = centers[id] {
                    draft.nodes[index].center = center
                }
            }
        }
    }

    private func undoEditor() {
        guard editorHistoryIndex > 0 else { return }
        editorHistoryIndex -= 1
        editorDraft = editorHistory[editorHistoryIndex]
        dragBaseCenters = [:]
    }

    private func redoEditor() {
        guard editorHistoryIndex >= 0,
              editorHistoryIndex < editorHistory.count - 1 else { return }
        editorHistoryIndex += 1
        editorDraft = editorHistory[editorHistoryIndex]
        dragBaseCenters = [:]
    }

    private func validateEditorDraft() {
        guard let draft = editorDraft else { return }
        do {
            _ = try FlowYAMLEditorCodec.validate(
                definition: flowDefinition(from: draft),
                noFSCheck: true
            )
            editorInfoMessage = "Draft is valid (no-fs-check)."
            editorErrorMessage = nil
        } catch {
            editorErrorMessage = "Draft validation failed: \(error.localizedDescription)"
            editorInfoMessage = nil
        }
    }

    private func saveEditorDraft() async {
        guard var draft = editorDraft else { return }
        do {
            let definition = flowDefinition(from: draft)
            _ = try FlowYAMLEditorCodec.validate(definition: definition, noFSCheck: true)
            let yaml = try FlowYAMLEditorCodec.render(definition: definition)

            let fileURL = URL(fileURLWithPath: draft.flowPath)
            let fileManager = FileManager.default
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).bak-\(timestamp)")
            let tempURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).tmp")

            try fileManager.copyItem(at: fileURL, to: backupURL)
            try yaml.write(to: tempURL, atomically: true, encoding: .utf8)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try fileManager.moveItem(at: tempURL, to: fileURL)

            do {
                _ = try FlowValidator.validateFile(
                    atPath: fileURL.path,
                    options: .init(checkFileSystem: false)
                )
            } catch {
                if fileManager.fileExists(atPath: fileURL.path) {
                    try? fileManager.removeItem(at: fileURL)
                }
                try? fileManager.copyItem(at: backupURL, to: fileURL)
                throw error
            }

            try saveEditorLayout(for: draft)
            draft.isDirty = false
            editorDraft = draft
            pushEditorHistory(draft)
            editorInfoMessage = "Saved \(fileURL.lastPathComponent)."
            editorErrorMessage = nil

            await appState.loadFlows()
            await appState.selectFlowDefinition(draft.definitionID)
        } catch {
            editorErrorMessage = "Save failed: \(error.localizedDescription)"
            editorInfoMessage = nil
        }
    }

    private func handleNodeDragChanged(nodeID: String, translation: CGSize) {
        guard let draft = editorDraft,
              let nodeIndex = draft.nodes.firstIndex(where: { $0.id == nodeID }) else {
            return
        }
        let base = dragBaseCenters[nodeID] ?? draft.nodes[nodeIndex].center
        if dragBaseCenters[nodeID] == nil {
            dragBaseCenters[nodeID] = base
        }
        let proposed = CGPoint(x: base.x + translation.width, y: base.y + translation.height)
        let clamped = CGPoint(x: max(proposed.x, 120), y: max(proposed.y, 80))
        mutateEditorDraft(pushHistory: false, markDirty: false) { edited in
            guard let index = edited.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            edited.nodes[index].center = clamped
            edited.selectedNodeID = nodeID
        }
    }

    private func handleNodeDragEnded(nodeID: String, translation: CGSize) {
        guard let base = dragBaseCenters.removeValue(forKey: nodeID) else { return }
        let proposed = CGPoint(x: base.x + translation.width, y: base.y + translation.height)
        let clamped = CGPoint(x: max(proposed.x, 120), y: max(proposed.y, 80))
        mutateEditorDraft(pushHistory: true, markDirty: true) { edited in
            guard let index = edited.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            edited.nodes[index].center = clamped
            edited.selectedNodeID = nodeID
        }
    }

    private func editorEdges(for draft: FlowEditorDraft) -> [FlowEditorCanvasEdge] {
        let ids = Set(draft.nodes.map(\.id))
        var edges: [FlowEditorCanvasEdge] = []
        for node in draft.nodes {
            switch node.state.type {
            case .gate:
                if let on = node.state.on {
                    edges.append(
                        FlowEditorCanvasEdge(
                            fromID: node.id,
                            toID: on.pass,
                            label: "pass",
                            isBroken: !ids.contains(on.pass)
                        )
                    )
                    edges.append(
                        FlowEditorCanvasEdge(
                            fromID: node.id,
                            toID: on.needsAgent,
                            label: "needs_agent",
                            isBroken: !ids.contains(on.needsAgent)
                        )
                    )
                    edges.append(
                        FlowEditorCanvasEdge(
                            fromID: node.id,
                            toID: on.wait,
                            label: "wait",
                            isBroken: !ids.contains(on.wait)
                        )
                    )
                    edges.append(
                        FlowEditorCanvasEdge(
                            fromID: node.id,
                            toID: on.fail,
                            label: "fail",
                            isBroken: !ids.contains(on.fail)
                        )
                    )
                    if let parseError = on.parseError {
                        edges.append(
                            FlowEditorCanvasEdge(
                                fromID: node.id,
                                toID: parseError,
                                label: "parse_error",
                                isBroken: !ids.contains(parseError)
                            )
                        )
                    }
                }
            case .agent, .wait, .script:
                if let next = node.state.next {
                    edges.append(
                        FlowEditorCanvasEdge(
                            fromID: node.id,
                            toID: next,
                            label: "next",
                            isBroken: !ids.contains(next)
                        )
                    )
                }
            case .end:
                break
            }
        }
        return edges
    }

    private func editorCanvasSize(for draft: FlowEditorDraft) -> CGSize {
        let maxX = max(draft.nodes.map { $0.center.x }.max() ?? 0, 1000)
        let maxY = max(draft.nodes.map { $0.center.y }.max() ?? 0, 700)
        return CGSize(width: maxX + 320, height: maxY + 260)
    }

    private func editorNodeSummary(_ state: FlowStateDefinition) -> String {
        switch state.type {
        case .gate:
            return "run=\(state.run ?? "—")"
        case .agent:
            return "task=\(state.task ?? "—") counter=\(state.counter ?? "—")"
        case .wait:
            if let seconds = state.seconds {
                return "seconds=\(seconds)"
            }
            if let secondsFrom = state.secondsFrom {
                return "seconds_from=\(secondsFrom)"
            }
            return "wait"
        case .script:
            return "run=\(state.run ?? "—")"
        case .end:
            return "status=\(state.endStatus?.rawValue ?? "success")"
        }
    }

    private func flowDefinition(from draft: FlowEditorDraft) -> FlowYAMLDefinition {
        let fallbackStart = draft.nodes.first?.id ?? draft.start
        let validStart = draft.nodes.contains(where: { $0.id == draft.start }) ? draft.start : fallbackStart
        return FlowYAMLDefinition(
            version: draft.version,
            start: validStart,
            defaults: draft.defaults,
            context: draft.context,
            states: draft.nodes.map(\.state)
        )
    }

    private func sidecarLayoutPath(for flowPath: String) -> String {
        "\(flowPath).layout.json"
    }

    private func loadEditorLayout(forFlowPath flowPath: String) -> [String: CGPoint]? {
        let path = sidecarLayoutPath(for: flowPath)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode(FlowEditorLayoutFile.self, from: data) else {
            return nil
        }
        return decoded.nodes.mapValues {
            CGPoint(x: $0.x, y: $0.y)
        }
    }

    private func saveEditorLayout(for draft: FlowEditorDraft) throws {
        let path = sidecarLayoutPath(for: draft.flowPath)
        let nodes = Dictionary(uniqueKeysWithValues: draft.nodes.map { node in
            (node.id, FlowEditorPoint(x: node.center.x, y: node.center.y))
        })
        let payload = FlowEditorLayoutFile(nodes: nodes)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private func autoLayoutCenters(for definition: FlowYAMLDefinition) -> [String: CGPoint] {
        let stateMap = Dictionary(uniqueKeysWithValues: definition.states.map { ($0.id, $0) })
        var depth: [String: Int] = [definition.start: 0]
        var queue: [String] = [definition.start]

        func targets(for state: FlowStateDefinition) -> [String] {
            switch state.type {
            case .gate:
                guard let on = state.on else { return [] }
                return [on.pass, on.needsAgent, on.wait, on.fail] + (on.parseError.map { [$0] } ?? [])
            case .agent, .wait, .script:
                return state.next.map { [$0] } ?? []
            case .end:
                return []
            }
        }

        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard let state = stateMap[current] else { continue }
            let currentDepth = depth[current, default: 0]
            for target in targets(for: state) where depth[target] == nil {
                depth[target] = currentDepth + 1
                queue.append(target)
            }
        }

        var grouped: [Int: [String]] = [:]
        for state in definition.states {
            let rank = depth[state.id] ?? (depth.values.max() ?? 0) + 1
            grouped[rank, default: []].append(state.id)
        }

        var centers: [String: CGPoint] = [:]
        for rank in grouped.keys.sorted() {
            let ids = grouped[rank, default: []]
            for (index, id) in ids.enumerated() {
                centers[id] = CGPoint(
                    x: 160 + CGFloat(rank) * 260,
                    y: 120 + CGFloat(index) * 140
                )
            }
        }
        return centers
    }

    private func defaultState(
        type: FlowStateType,
        id: String,
        fallbackTarget: String?
    ) -> FlowStateDefinition {
        let target = fallbackTarget ?? id
        var state = FlowStateDefinition(id: id, type: type)
        switch type {
        case .gate:
            state.run = "./gate.sh"
            state.on = FlowGateTransitions(
                pass: target,
                needsAgent: target,
                wait: target,
                fail: target,
                parseError: nil
            )
            state.parseMode = .jsonLastLine
        case .agent:
            state.task = "TODO: describe task"
            state.next = target
            state.counter = "agent_round"
            state.maxRounds = 3
        case .wait:
            state.next = target
            state.seconds = 5
        case .script:
            state.run = "./script.sh"
            state.next = target
        case .end:
            state.endStatus = .success
        }
        return state
    }

    private func nextEditorStateID(base: String, existingIDs: Set<String>) -> String {
        let sanitized = base.replacingOccurrences(of: "_", with: "-")
        if !existingIDs.contains(sanitized) {
            return sanitized
        }
        var index = 2
        while existingIDs.contains("\(sanitized)-\(index)") {
            index += 1
        }
        return "\(sanitized)-\(index)"
    }

    private func normalizedOptional(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
