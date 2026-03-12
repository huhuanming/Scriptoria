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

    init(version: Int = 3, nodes: [String: FlowEditorPoint]) {
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
    var semantic: FlowEditorEdgeSemantic
    var sourceSide: FlowEditorPortSide
    var targetSide: FlowEditorPortSide
    var sourceSlot: Int
    var sourceSlotCount: Int
    var targetSlot: Int
    var targetSlotCount: Int
}

private struct FlowEditorEdgeRoute {
    var points: [CGPoint]
    var labelPosition: CGPoint
}

private struct FlowEditorRouteJump {
    var point: CGPoint
    var isHorizontal: Bool
}

private struct FlowEditorRoutingResult {
    var routes: [String: FlowEditorEdgeRoute]
    var jumps: [String: [FlowEditorRouteJump]]
    var metrics: FlowEditorRoutingMetrics
}

private struct FlowEditorRoutingMetrics {
    var crossings: Int
    var overlaps: Int
    var bends: Int
    var length: Int
    var score: Int

    static let zero = FlowEditorRoutingMetrics(
        crossings: 0,
        overlaps: 0,
        bends: 0,
        length: 0,
        score: 0
    )
}

private enum FlowEditorViewMode: String, CaseIterable, Identifiable {
    case simplified = "Simple"
    case full = "Full"

    var id: String { rawValue }
}

private enum FlowEditorLabelMode: String, CaseIterable, Identifiable {
    case minimal = "Minimal"
    case focused = "Focused"
    case all = "All"

    var id: String { rawValue }
}

private enum FlowEditorEdgeSemantic: String {
    case next
    case pass
    case needsAgent
    case wait
    case fail
    case parseError
    case other
}

private enum FlowEditorPortSide: String, Hashable {
    case north
    case east
    case south
    case west
}

private struct FlowEditorPortKey: Hashable {
    var nodeID: String
    var side: FlowEditorPortSide
}

private struct FlowEditorFocusSnapshot {
    var selectedID: String?
    var relatedNodeIDs: Set<String>
    var highlightedEdgeIDs: Set<String>

    static let none = FlowEditorFocusSnapshot(
        selectedID: nil,
        relatedNodeIDs: [],
        highlightedEdgeIDs: []
    )
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
    @State private var isNodeDragging = false
    @State private var editorCanvasZoom: CGFloat = 1
    @State private var editorViewMode: FlowEditorViewMode = .simplified
    @State private var editorLabelMode: FlowEditorLabelMode = .minimal
    @State private var editorFocusSelection = true
    @State private var editorStrictPorts = true
    @State private var editorEnforceLayoutGate = true

    private let editorCanvasCoordinateSpace = "flow-editor-canvas"
    private let editorNodeSize = CGSize(width: 200, height: 94)
    private let editorNodeCornerRadius: CGFloat = 10
    private let editorCanvasMinZoom: CGFloat = 0.4
    private let editorCanvasMaxZoom: CGFloat = 2.4
    private let editorCanvasZoomStep: CGFloat = 0.1
    private let editorLayoutGateMaxCrossings = 2
    private let editorLayoutGateMaxOverlaps = 0

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

                Menu("View") {
                    Picker("Graph", selection: $editorViewMode) {
                        ForEach(FlowEditorViewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    Picker("Labels", selection: $editorLabelMode) {
                        ForEach(FlowEditorLabelMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    Toggle("Focus Selection", isOn: $editorFocusSelection)
                    Toggle("Strict Ports", isOn: $editorStrictPorts)
                    Toggle("Enforce Layout Gate", isOn: $editorEnforceLayoutGate)
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
        let nodeRects = nodeCenters.mapValues { center in
            editorNodeRect(center: center)
        }
        let allEdges = editorEdges(for: draft, strictPorts: editorStrictPorts)
        let mainPathIDs = editorMainPathIDs(for: draft)
        let mainPathEdgeIDs = editorMainPathEdgeIDs(for: mainPathIDs)
        let visibleEdges = editorVisibleEdges(
            allEdges: allEdges,
            mainPathEdgeIDs: mainPathEdgeIDs,
            mainPathIDs: mainPathIDs,
            selectedNodeID: draft.selectedNodeID
        )
        let mainY: CGFloat = {
            let points = mainPathIDs.compactMap { nodeCenters[$0]?.y }
            guard !points.isEmpty else { return canvasSize.height * 0.45 }
            return points.reduce(0, +) / CGFloat(points.count)
        }()
        let focus = editorFocusSnapshot(
            selectedNodeID: draft.selectedNodeID,
            visibleEdges: visibleEdges
        )
        let routing = editorRouting(
            for: visibleEdges,
            nodeCenters: nodeCenters,
            nodeRects: nodeRects,
            mainPathEdgeIDs: mainPathEdgeIDs
        )
        let scaledSize = CGSize(
            width: canvasSize.width * editorCanvasZoom,
            height: canvasSize.height * editorCanvasZoom
        )

        ZStack(alignment: .bottomTrailing) {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: canvasSize.width, height: canvasSize.height)

                    editorLaneGuideOverlay(canvasSize: canvasSize, mainY: mainY)

                    ForEach(visibleEdges) { edge in
                        let showsLabel = editorShouldShowLabel(
                            for: edge,
                            focus: focus,
                            mainPathEdgeIDs: mainPathEdgeIDs
                        )
                        let highlighted = !editorFocusSelection || focus.selectedID == nil || focus.highlightedEdgeIDs.contains(edge.id)
                        let route = routing.routes[edge.id] ?? FlowEditorEdgeRoute(
                            points: [
                                nodeCenters[edge.fromID] ?? .zero,
                                nodeCenters[edge.toID] ?? .zero
                            ],
                            labelPosition: nodeCenters[edge.toID] ?? .zero
                        )
                        let jumps = routing.jumps[edge.id] ?? []
                        editorEdgeView(
                            edge: edge,
                            route: route,
                            jumps: jumps,
                            highlighted: highlighted,
                            showsLabel: showsLabel,
                            mainPathEdgeIDs: mainPathEdgeIDs
                        )
                    }

                    ForEach(draft.nodes) { node in
                        let isSelected = node.id == draft.selectedNodeID
                        let isRelated = !editorFocusSelection || focus.selectedID == nil || focus.relatedNodeIDs.contains(node.id)
                        editorNodeCard(
                            node: node,
                            isSelected: isSelected,
                            isDimmed: !isRelated,
                            isOnMainPath: mainPathIDs.contains(node.id)
                        )
                            .position(node.center)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .scaleEffect(editorCanvasZoom, anchor: .topLeading)
                .frame(width: scaledSize.width, height: scaledSize.height, alignment: .topLeading)
                .coordinateSpace(name: editorCanvasCoordinateSpace)
            }
            .scrollDisabled(isNodeDragging)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    Button {
                        adjustEditorCanvasZoom(by: -editorCanvasZoomStep)
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 20, height: 20)
                    }
                    .disabled(editorCanvasZoom <= editorCanvasMinZoom + 0.001)

                    Button {
                        setEditorCanvasZoom(1)
                    } label: {
                        Text("\(Int((editorCanvasZoom * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .frame(minWidth: 42)
                    }
                    .help("Reset zoom")

                    Button {
                        adjustEditorCanvasZoom(by: editorCanvasZoomStep)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                    }
                    .disabled(editorCanvasZoom >= editorCanvasMaxZoom - 0.001)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
            .overlay(alignment: .topLeading) {
                if !visibleEdges.isEmpty {
                    editorRoutingMetricsPanel(
                        metrics: routing.metrics,
                        edgeCount: visibleEdges.count
                    )
                    .padding(12)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func editorLaneGuideOverlay(canvasSize: CGSize, mainY: CGFloat) -> some View {
        let laneRows: [(label: String, y: CGFloat, color: Color)] = [
            ("wait lane", mainY - 340, .blue),
            ("main lane", mainY, .accentColor),
            ("fail lane", mainY + 340, .red)
        ]
        ForEach(Array(laneRows.enumerated()), id: \.offset) { _, lane in
            if lane.y > 24, lane.y < canvasSize.height - 24 {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: lane.y))
                    path.addLine(to: CGPoint(x: canvasSize.width, y: lane.y))
                }
                .stroke(
                    lane.color.opacity(0.23),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 8])
                )

                Text(lane.label)
                    .font(.caption2.monospaced())
                    .foregroundStyle(lane.color.opacity(0.7))
                    .position(x: 62, y: lane.y - 10)
            }
        }
    }

    @ViewBuilder
    private func editorRoutingMetricsPanel(metrics: FlowEditorRoutingMetrics, edgeCount: Int) -> some View {
        let gateBlocked = editorLayoutGateFailureReason(for: metrics) != nil
        VStack(alignment: .leading, spacing: 4) {
            Text("edges \(edgeCount)  x \(metrics.crossings)  o \(metrics.overlaps)  b \(metrics.bends)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
            Text("score \(metrics.score)  len \(metrics.length)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if editorEnforceLayoutGate {
                Text(gateBlocked ? "gate blocked" : "gate pass")
                    .font(.caption2.monospaced())
                    .foregroundStyle(gateBlocked ? .red : .green)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func editorEdgeView(
        edge: FlowEditorCanvasEdge,
        route: FlowEditorEdgeRoute,
        jumps: [FlowEditorRouteJump],
        highlighted: Bool,
        showsLabel: Bool,
        mainPathEdgeIDs: Set<String>
    ) -> some View {
        let strokeColor = editorEdgeColor(edge: edge, mainPathEdgeIDs: mainPathEdgeIDs)
        let edgeOpacity: Double = highlighted ? 0.88 : 0.22
        let lineWidth: CGFloat = highlighted ? 2.1 : 1.35
        let dash: [CGFloat] = edge.isBroken ? [6, 5] : []

        roundedOrthogonalPath(points: route.points, cornerRadius: 14)
            .stroke(strokeColor.opacity(edgeOpacity), style: StrokeStyle(lineWidth: lineWidth, dash: dash))

        editorArrowHeadPath(for: route.points)
            .fill(strokeColor.opacity(highlighted ? 0.9 : 0.3))

        ForEach(Array(jumps.enumerated()), id: \.offset) { _, jump in
            editorLineJumpView(jump: jump, color: strokeColor, lineWidth: lineWidth)
        }

        if showsLabel {
            Text(edge.label)
                .font(.caption2.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: .textBackgroundColor), in: Capsule())
                .foregroundStyle(strokeColor.opacity(highlighted ? 1 : 0.55))
                .position(route.labelPosition)
        }
    }

    @ViewBuilder
    private func editorLineJumpView(jump: FlowEditorRouteJump, color: Color, lineWidth: CGFloat) -> some View {
        let radius: CGFloat = max(4.5, lineWidth * 2.3)
        let rect = CGRect(
            x: jump.point.x - radius,
            y: jump.point.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        Circle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: radius * 2.15, height: radius * 2.15)
            .position(jump.point)

        Path { path in
            if jump.isHorizontal {
                path.addArc(
                    center: jump.point,
                    radius: radius,
                    startAngle: .degrees(180),
                    endAngle: .degrees(0),
                    clockwise: false
                )
            } else {
                path.addArc(
                    center: jump.point,
                    radius: radius,
                    startAngle: .degrees(270),
                    endAngle: .degrees(90),
                    clockwise: false
                )
            }
        }
        .stroke(color.opacity(0.95), style: StrokeStyle(lineWidth: max(1.6, lineWidth)))
        .frame(width: rect.width, height: rect.height)
        .position(jump.point)
    }

    @ViewBuilder
    private func editorNodeCard(
        node: FlowEditorNodeDraft,
        isSelected: Bool,
        isDimmed: Bool,
        isOnMainPath: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(node.state.id)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if isOnMainPath {
                    Text("main")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                }
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
        .frame(width: editorNodeSize.width, height: editorNodeSize.height)
        .background(
            RoundedRectangle(cornerRadius: editorNodeCornerRadius)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: editorNodeCornerRadius)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
        .opacity(isDimmed ? 0.35 : 1)
        .onTapGesture {
            selectEditorNode(node.id)
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(editorCanvasCoordinateSpace))
                .onChanged { value in
                    handleNodeDragChanged(nodeID: node.id, value: value)
                }
                .onEnded { value in
                    handleNodeDragEnded(nodeID: node.id, value: value)
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
            isNodeDragging = false
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
        isNodeDragging = false
    }

    private func redoEditor() {
        guard editorHistoryIndex >= 0,
              editorHistoryIndex < editorHistory.count - 1 else { return }
        editorHistoryIndex += 1
        editorDraft = editorHistory[editorHistoryIndex]
        dragBaseCenters = [:]
        isNodeDragging = false
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
            if editorEnforceLayoutGate {
                let metrics = editorDraftRoutingMetrics(for: draft, strictPorts: editorStrictPorts)
                if let reason = editorLayoutGateFailureReason(for: metrics) {
                    editorErrorMessage = "Save blocked by layout gate: \(reason). Re-layout nodes or disable View > Enforce Layout Gate."
                    editorInfoMessage = nil
                    return
                }
            }

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

    private func editorDraftRoutingMetrics(for draft: FlowEditorDraft, strictPorts: Bool) -> FlowEditorRoutingMetrics {
        let centers = Dictionary(uniqueKeysWithValues: draft.nodes.map { ($0.id, $0.center) })
        let rects = centers.mapValues { center in
            editorNodeRect(center: center)
        }
        let edges = editorEdges(for: draft, strictPorts: strictPorts)
        let mainPathIDs = editorMainPathIDs(for: draft)
        let mainPathEdgeIDs = editorMainPathEdgeIDs(for: mainPathIDs)
        let routing = editorRouting(
            for: edges,
            nodeCenters: centers,
            nodeRects: rects,
            mainPathEdgeIDs: mainPathEdgeIDs
        )
        return routing.metrics
    }

    private func editorLayoutGateFailureReason(for metrics: FlowEditorRoutingMetrics) -> String? {
        var issues: [String] = []
        if metrics.overlaps > editorLayoutGateMaxOverlaps {
            issues.append("overlaps \(metrics.overlaps) > \(editorLayoutGateMaxOverlaps)")
        }
        if metrics.crossings > editorLayoutGateMaxCrossings {
            issues.append("crossings \(metrics.crossings) > \(editorLayoutGateMaxCrossings)")
        }
        if issues.isEmpty { return nil }
        return issues.joined(separator: ", ")
    }

    private func handleNodeDragChanged(nodeID: String, value: DragGesture.Value) {
        guard let draft = editorDraft,
              let nodeIndex = draft.nodes.firstIndex(where: { $0.id == nodeID }) else {
            return
        }
        let base = dragBaseCenters[nodeID] ?? draft.nodes[nodeIndex].center
        if dragBaseCenters[nodeID] == nil {
            dragBaseCenters[nodeID] = base
        }
        isNodeDragging = true
        let zoom = max(editorCanvasZoom, 0.001)
        let deltaX = (value.location.x - value.startLocation.x) / zoom
        let deltaY = (value.location.y - value.startLocation.y) / zoom
        let proposed = CGPoint(x: base.x + deltaX, y: base.y + deltaY)
        let clamped = CGPoint(x: max(proposed.x, 120), y: max(proposed.y, 80))
        mutateEditorDraft(pushHistory: false, markDirty: false) { edited in
            guard let index = edited.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            edited.nodes[index].center = clamped
            edited.selectedNodeID = nodeID
        }
    }

    private func handleNodeDragEnded(nodeID: String, value: DragGesture.Value) {
        isNodeDragging = false
        guard let base = dragBaseCenters.removeValue(forKey: nodeID) else { return }
        let zoom = max(editorCanvasZoom, 0.001)
        let deltaX = (value.location.x - value.startLocation.x) / zoom
        let deltaY = (value.location.y - value.startLocation.y) / zoom
        let proposed = CGPoint(x: base.x + deltaX, y: base.y + deltaY)
        let clamped = CGPoint(x: max(proposed.x, 120), y: max(proposed.y, 80))
        mutateEditorDraft(pushHistory: true, markDirty: true) { edited in
            guard let index = edited.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            edited.nodes[index].center = clamped
            edited.selectedNodeID = nodeID
        }
    }

    private func editorTargets(for state: FlowStateDefinition) -> [(label: String, target: String)] {
        switch state.type {
        case .gate:
            guard let on = state.on else { return [] }
            var targets: [(label: String, target: String)] = [
                (label: "needs_agent", target: on.needsAgent),
                (label: "pass", target: on.pass),
                (label: "wait", target: on.wait),
                (label: "fail", target: on.fail)
            ]
            if let parseError = on.parseError {
                targets.append((label: "parse_error", target: parseError))
            }
            return targets
        case .agent, .wait, .script:
            if let next = state.next {
                return [(label: "next", target: next)]
            }
            return []
        case .end:
            return []
        }
    }

    private func editorMainPath(
        start: String,
        stateMap: [String: FlowStateDefinition],
        stateIDs: Set<String>
    ) -> [String] {
        var path: [String] = []
        var visited: Set<String> = []
        var current = start

        while stateIDs.contains(current), !visited.contains(current) {
            path.append(current)
            visited.insert(current)
            guard let state = stateMap[current] else { break }
            let candidates = editorTargets(for: state).filter { stateIDs.contains($0.target) }
            let next = candidates.first(where: { !visited.contains($0.target) })?.target
            guard let next else { break }
            current = next
        }

        if path.isEmpty, let fallback = stateMap.keys.sorted().first {
            return [fallback]
        }
        return path
    }

    private func editorMainPathIDs(for draft: FlowEditorDraft) -> [String] {
        let stateMap = Dictionary(uniqueKeysWithValues: draft.nodes.map { ($0.id, $0.state) })
        let stateIDs = Set(draft.nodes.map(\.id))
        return editorMainPath(start: draft.start, stateMap: stateMap, stateIDs: stateIDs)
    }

    private func editorMainPathEdgeIDs(for mainPathIDs: [String]) -> Set<String> {
        guard mainPathIDs.count > 1 else { return [] }
        let labels = ["next", "needs_agent", "pass", "wait", "fail", "parse_error"]
        var edgeIDs: Set<String> = []
        for index in 0..<(mainPathIDs.count - 1) {
            let from = mainPathIDs[index]
            let to = mainPathIDs[index + 1]
            for label in labels {
                edgeIDs.insert("\(from)->\(label)->\(to)")
            }
        }
        return edgeIDs
    }

    private func editorEdgeSemantic(for label: String) -> FlowEditorEdgeSemantic {
        switch label {
        case "next":
            return .next
        case "pass":
            return .pass
        case "needs_agent":
            return .needsAgent
        case "wait":
            return .wait
        case "fail":
            return .fail
        case "parse_error":
            return .parseError
        default:
            return .other
        }
    }

    private func editorEdgeColor(edge: FlowEditorCanvasEdge, mainPathEdgeIDs: Set<String>) -> Color {
        if edge.isBroken {
            return .red
        }
        if mainPathEdgeIDs.contains(edge.id) {
            return .accentColor
        }
        switch edge.semantic {
        case .next:
            return .secondary
        case .pass:
            return .green
        case .needsAgent:
            return .orange
        case .wait:
            return .blue
        case .fail:
            return .red
        case .parseError:
            return .pink
        case .other:
            return .secondary
        }
    }

    private func editorVisibleEdges(
        allEdges: [FlowEditorCanvasEdge],
        mainPathEdgeIDs: Set<String>,
        mainPathIDs: [String],
        selectedNodeID: String?
    ) -> [FlowEditorCanvasEdge] {
        guard editorViewMode == .simplified else {
            return allEdges
        }

        let mainNodeSet = Set(mainPathIDs)
        return allEdges.filter { edge in
            if mainPathEdgeIDs.contains(edge.id) {
                return true
            }
            if editorEdgeTouchesSelection(edge: edge, selectedNodeID: selectedNodeID) {
                return true
            }
            switch edge.semantic {
            case .needsAgent:
                return true
            case .pass:
                return mainNodeSet.contains(edge.fromID)
            case .next:
                return false
            case .wait, .fail, .parseError, .other:
                return false
            }
        }
    }

    private func editorFocusSnapshot(
        selectedNodeID: String?,
        visibleEdges: [FlowEditorCanvasEdge]
    ) -> FlowEditorFocusSnapshot {
        guard editorFocusSelection,
              let selectedNodeID else {
            return .none
        }

        var outgoing: [String: [String]] = [:]
        var incoming: [String: [String]] = [:]
        var edgeIDsByPair: [String: Set<String>] = [:]

        for edge in visibleEdges where !edge.isBroken {
            outgoing[edge.fromID, default: []].append(edge.toID)
            incoming[edge.toID, default: []].append(edge.fromID)
            edgeIDsByPair["\(edge.fromID)->\(edge.toID)", default: []].insert(edge.id)
        }

        func bfs(seed: String, graph: [String: [String]]) -> Set<String> {
            var visited: Set<String> = [seed]
            var queue: [String] = [seed]
            while !queue.isEmpty {
                let current = queue.removeFirst()
                for next in graph[current, default: []] where !visited.contains(next) {
                    visited.insert(next)
                    queue.append(next)
                }
            }
            return visited
        }

        let downstream = bfs(seed: selectedNodeID, graph: outgoing)
        let upstream = bfs(seed: selectedNodeID, graph: incoming)
        let related = downstream.union(upstream)

        var highlightedEdges: Set<String> = []
        for from in related {
            for to in outgoing[from, default: []] where related.contains(to) {
                highlightedEdges.formUnion(edgeIDsByPair["\(from)->\(to)", default: []])
            }
        }

        return FlowEditorFocusSnapshot(
            selectedID: selectedNodeID,
            relatedNodeIDs: related,
            highlightedEdgeIDs: highlightedEdges
        )
    }

    private func editorShouldShowLabel(
        for edge: FlowEditorCanvasEdge,
        focus: FlowEditorFocusSnapshot,
        mainPathEdgeIDs: Set<String>
    ) -> Bool {
        switch editorLabelMode {
        case .all:
            return true
        case .focused:
            guard focus.selectedID != nil else {
                return mainPathEdgeIDs.contains(edge.id) || edge.semantic != .next
            }
            return focus.highlightedEdgeIDs.contains(edge.id)
        case .minimal:
            let semantic = edge.semantic
            if semantic == .next {
                return false
            }
            if mainPathEdgeIDs.contains(edge.id) {
                return true
            }
            return editorEdgeTouchesSelection(edge: edge, selectedNodeID: focus.selectedID)
        }
    }

    private func editorEdgeTouchesSelection(edge: FlowEditorCanvasEdge, selectedNodeID: String?) -> Bool {
        guard let selectedNodeID else { return false }
        return edge.fromID == selectedNodeID || edge.toID == selectedNodeID
    }

    private func editorRankMap(for draft: FlowEditorDraft) -> [String: Int] {
        let stateMap = Dictionary(uniqueKeysWithValues: draft.nodes.map { ($0.id, $0.state) })
        let stateIDs = Set(draft.nodes.map(\.id))
        var incoming: [String: [String]] = [:]
        for node in draft.nodes {
            for target in editorTargets(for: node.state).map(\.target) where stateIDs.contains(target) {
                incoming[target, default: []].append(node.id)
            }
        }

        let mainPath = editorMainPath(start: draft.start, stateMap: stateMap, stateIDs: stateIDs)
        var rank: [String: Int] = [:]
        for (index, id) in mainPath.enumerated() {
            rank[id] = index
        }

        var unresolved = stateIDs.subtracting(rank.keys)
        var safety = 0
        while !unresolved.isEmpty, safety < max(1, draft.nodes.count * 5) {
            safety += 1
            var progressed = false
            for id in Array(unresolved) {
                let parentRanks = incoming[id, default: []].compactMap { rank[$0] }
                guard !parentRanks.isEmpty else { continue }
                rank[id] = (parentRanks.max() ?? 0) + 1
                unresolved.remove(id)
                progressed = true
            }
            if !progressed {
                break
            }
        }

        if !unresolved.isEmpty {
            let spillStart = (rank.values.max() ?? 0) + 1
            for (index, id) in unresolved.sorted().enumerated() {
                rank[id] = spillStart + index
            }
        }

        return rank
    }

    private func editorPortSides(
        semantic: FlowEditorEdgeSemantic,
        fromID: String,
        toID: String,
        rankByID: [String: Int],
        strictPorts: Bool
    ) -> (source: FlowEditorPortSide, target: FlowEditorPortSide) {
        let sourceRank = rankByID[fromID] ?? 0
        let targetRank = rankByID[toID] ?? (sourceRank + 1)
        let isBackEdge = targetRank <= sourceRank

        if strictPorts {
            switch semantic {
            case .wait:
                return (.north, .south)
            case .fail, .parseError:
                return (.south, .north)
            case .next, .pass, .needsAgent, .other:
                if isBackEdge {
                    return (.north, .south)
                }
                return (.east, .west)
            }
        }

        switch semantic {
        case .wait:
            return (.north, .south)
        case .fail, .parseError:
            return (.south, .north)
        case .next, .pass, .needsAgent, .other:
            if targetRank >= sourceRank {
                return (.east, .west)
            }
            return (.west, .east)
        }
    }

    private func editorEdges(for draft: FlowEditorDraft, strictPorts: Bool) -> [FlowEditorCanvasEdge] {
        let ids = Set(draft.nodes.map(\.id))
        let rankByID = editorRankMap(for: draft)
        let centers = Dictionary(uniqueKeysWithValues: draft.nodes.map { ($0.id, $0.center) })
        var edges: [FlowEditorCanvasEdge] = []
        for node in draft.nodes {
            let targets = editorTargets(for: node.state)
            for target in targets {
                let semantic = editorEdgeSemantic(for: target.label)
                let sides = editorPortSides(
                    semantic: semantic,
                    fromID: node.id,
                    toID: target.target,
                    rankByID: rankByID,
                    strictPorts: strictPorts
                )
                edges.append(
                    FlowEditorCanvasEdge(
                        fromID: node.id,
                        toID: target.target,
                        label: target.label,
                        isBroken: !ids.contains(target.target),
                        semantic: semantic,
                        sourceSide: sides.source,
                        targetSide: sides.target,
                        sourceSlot: 0,
                        sourceSlotCount: 1,
                        targetSlot: 0,
                        targetSlotCount: 1
                    )
                )
            }
        }

        var sourceGroups: [FlowEditorPortKey: [Int]] = [:]
        var targetGroups: [FlowEditorPortKey: [Int]] = [:]
        for (index, edge) in edges.enumerated() {
            sourceGroups[FlowEditorPortKey(nodeID: edge.fromID, side: edge.sourceSide), default: []].append(index)
            targetGroups[FlowEditorPortKey(nodeID: edge.toID, side: edge.targetSide), default: []].append(index)
        }

        func slotSort(_ lhsIndex: Int, _ rhsIndex: Int, useTargets: Bool) -> Bool {
            let lhsPeerID = useTargets ? edges[lhsIndex].toID : edges[lhsIndex].fromID
            let rhsPeerID = useTargets ? edges[rhsIndex].toID : edges[rhsIndex].fromID
            let lhsCenter = centers[lhsPeerID] ?? .zero
            let rhsCenter = centers[rhsPeerID] ?? .zero
            if abs(lhsCenter.y - rhsCenter.y) > 0.5 {
                return lhsCenter.y < rhsCenter.y
            }
            if abs(lhsCenter.x - rhsCenter.x) > 0.5 {
                return lhsCenter.x < rhsCenter.x
            }
            return edges[lhsIndex].id < edges[rhsIndex].id
        }

        for (_, group) in sourceGroups {
            let sorted = group.sorted { lhs, rhs in
                slotSort(lhs, rhs, useTargets: true)
            }
            let count = sorted.count
            for (slot, edgeIndex) in sorted.enumerated() {
                edges[edgeIndex].sourceSlot = slot
                edges[edgeIndex].sourceSlotCount = count
            }
        }

        for (_, group) in targetGroups {
            let sorted = group.sorted { lhs, rhs in
                slotSort(lhs, rhs, useTargets: false)
            }
            let count = sorted.count
            for (slot, edgeIndex) in sorted.enumerated() {
                edges[edgeIndex].targetSlot = slot
                edges[edgeIndex].targetSlotCount = count
            }
        }

        return edges
    }

    private func editorCanvasSize(for draft: FlowEditorDraft) -> CGSize {
        let maxX = max(draft.nodes.map { $0.center.x }.max() ?? 0, 1000)
        let maxY = max(draft.nodes.map { $0.center.y }.max() ?? 0, 700)
        return CGSize(width: maxX + 320, height: maxY + 260)
    }

    private func editorNodeRect(center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - (editorNodeSize.width / 2),
            y: center.y - (editorNodeSize.height / 2),
            width: editorNodeSize.width,
            height: editorNodeSize.height
        )
    }

    private func editorRouting(
        for edges: [FlowEditorCanvasEdge],
        nodeCenters: [String: CGPoint],
        nodeRects: [String: CGRect],
        mainPathEdgeIDs: Set<String>
    ) -> FlowEditorRoutingResult {
        guard !edges.isEmpty else {
            return FlowEditorRoutingResult(routes: [:], jumps: [:], metrics: .zero)
        }

        func edgePriority(_ edge: FlowEditorCanvasEdge) -> Int {
            if mainPathEdgeIDs.contains(edge.id) {
                return 0
            }
            switch edge.semantic {
            case .next, .pass:
                return 1
            case .needsAgent:
                return 2
            case .wait:
                return 3
            case .fail, .parseError:
                return 4
            case .other:
                return 5
            }
        }

        let orderedEdges = edges.sorted { lhs, rhs in
            let l = edgePriority(lhs)
            let r = edgePriority(rhs)
            if l != r { return l < r }
            if lhs.fromID != rhs.fromID { return lhs.fromID < rhs.fromID }
            if lhs.toID != rhs.toID { return lhs.toID < rhs.toID }
            return lhs.label < rhs.label
        }

        var routes: [String: FlowEditorEdgeRoute] = [:]
        for edge in orderedEdges {
            let existing = routes.values.map(\.points)
            let from = nodeCenters[edge.fromID] ?? .zero
            let to = nodeCenters[edge.toID] ?? CGPoint(x: from.x + 180, y: from.y)
            routes[edge.id] = editorRoute(
                for: edge,
                nodeRects: nodeRects,
                fallbackFrom: from,
                fallbackTo: to,
                existingRoutes: existing
            )
        }

        var bestMetrics = editorRoutingMetrics(routes: routes, orderedEdges: orderedEdges)
        var iteration = 0
        while iteration < 2 {
            iteration += 1
            let edgeConflicts = editorRouteConflicts(routes: routes, orderedEdges: orderedEdges)
            let conflicted = edgeConflicts
                .filter { $0.value.crossings + $0.value.overlaps > 0 }
                .sorted { lhs, rhs in
                    let lv = lhs.value.crossings * 100 + lhs.value.overlaps
                    let rv = rhs.value.crossings * 100 + rhs.value.overlaps
                    if lv != rv { return lv > rv }
                    return lhs.key < rhs.key
                }
            guard !conflicted.isEmpty else { break }

            let maxRework = max(1, min(conflicted.count, orderedEdges.count / 3))
            var improved = false

            for (edgeID, _) in conflicted.prefix(maxRework) {
                guard let edge = orderedEdges.first(where: { $0.id == edgeID }),
                      routes[edgeID] != nil else { continue }
                let original = routes[edgeID]
                routes[edgeID] = nil
                let existing = routes.values.map(\.points)
                let from = nodeCenters[edge.fromID] ?? .zero
                let to = nodeCenters[edge.toID] ?? CGPoint(x: from.x + 180, y: from.y)
                routes[edgeID] = editorRoute(
                    for: edge,
                    nodeRects: nodeRects,
                    fallbackFrom: from,
                    fallbackTo: to,
                    existingRoutes: existing
                )

                let metrics = editorRoutingMetrics(routes: routes, orderedEdges: orderedEdges)
                if metrics.score < bestMetrics.score {
                    bestMetrics = metrics
                    improved = true
                } else {
                    routes[edgeID] = original
                }
            }

            if !improved {
                break
            }
        }

        var jumps: [String: [FlowEditorRouteJump]] = [:]
        for i in 0..<orderedEdges.count {
            let edgeA = orderedEdges[i]
            guard let routeA = routes[edgeA.id] else { continue }
            for j in (i + 1)..<orderedEdges.count {
                let edgeB = orderedEdges[j]
                guard let routeB = routes[edgeB.id] else { continue }
                let intersections = editorRouteCrossings(pointsA: routeA.points, pointsB: routeB.points)
                guard !intersections.isEmpty else { continue }

                let priorityA = edgePriority(edgeA)
                let priorityB = edgePriority(edgeB)
                let jumperID: String
                let jumperRoute: FlowEditorEdgeRoute
                if priorityA > priorityB {
                    jumperID = edgeA.id
                    jumperRoute = routeA
                } else if priorityB > priorityA {
                    jumperID = edgeB.id
                    jumperRoute = routeB
                } else {
                    jumperID = edgeB.id
                    jumperRoute = routeB
                }

                for crossing in intersections {
                    if let jump = editorJumpPoint(at: crossing, on: jumperRoute.points) {
                        jumps[jumperID, default: []].append(jump)
                    }
                }
            }
        }

        for (edgeID, values) in jumps {
            jumps[edgeID] = editorUniqueJumps(values)
        }

        return FlowEditorRoutingResult(
            routes: routes,
            jumps: jumps,
            metrics: bestMetrics
        )
    }

    private struct FlowEditorRouteConflict {
        var crossings: Int
        var overlaps: Int
    }

    private func editorRouteConflicts(
        routes: [String: FlowEditorEdgeRoute],
        orderedEdges: [FlowEditorCanvasEdge]
    ) -> [String: FlowEditorRouteConflict] {
        var conflicts: [String: FlowEditorRouteConflict] = [:]
        for edge in orderedEdges {
            conflicts[edge.id] = .init(crossings: 0, overlaps: 0)
        }
        for i in 0..<orderedEdges.count {
            let edgeA = orderedEdges[i]
            guard let routeA = routes[edgeA.id] else { continue }
            for j in (i + 1)..<orderedEdges.count {
                let edgeB = orderedEdges[j]
                guard let routeB = routes[edgeB.id] else { continue }
                let metrics = editorRoutePairMetrics(pointsA: routeA.points, pointsB: routeB.points)
                if metrics.crossings == 0, metrics.overlaps == 0 {
                    continue
                }
                var a = conflicts[edgeA.id] ?? .init(crossings: 0, overlaps: 0)
                a.crossings += metrics.crossings
                a.overlaps += metrics.overlaps
                conflicts[edgeA.id] = a

                var b = conflicts[edgeB.id] ?? .init(crossings: 0, overlaps: 0)
                b.crossings += metrics.crossings
                b.overlaps += metrics.overlaps
                conflicts[edgeB.id] = b
            }
        }
        return conflicts
    }

    private func editorRoutingMetrics(
        routes: [String: FlowEditorEdgeRoute],
        orderedEdges: [FlowEditorCanvasEdge]
    ) -> FlowEditorRoutingMetrics {
        var bends = 0
        var length: CGFloat = 0
        for edge in orderedEdges {
            guard let route = routes[edge.id] else { continue }
            bends += max(route.points.count - 2, 0)
            length += editorPolylineLength(route.points)
        }

        var crossings = 0
        var overlaps = 0
        for i in 0..<orderedEdges.count {
            let edgeA = orderedEdges[i]
            guard let routeA = routes[edgeA.id] else { continue }
            for j in (i + 1)..<orderedEdges.count {
                let edgeB = orderedEdges[j]
                guard let routeB = routes[edgeB.id] else { continue }
                let metrics = editorRoutePairMetrics(pointsA: routeA.points, pointsB: routeB.points)
                crossings += metrics.crossings
                overlaps += metrics.overlaps
            }
        }

        let score = crossings * 10000
            + overlaps * 3000
            + bends * 40
            + Int(length.rounded())
        return FlowEditorRoutingMetrics(
            crossings: crossings,
            overlaps: overlaps,
            bends: bends,
            length: Int(length.rounded()),
            score: score
        )
    }

    private func editorUniqueJumps(_ values: [FlowEditorRouteJump]) -> [FlowEditorRouteJump] {
        var result: [FlowEditorRouteJump] = []
        for jump in values {
            if result.contains(where: {
                abs($0.point.x - jump.point.x) < 2
                    && abs($0.point.y - jump.point.y) < 2
            }) {
                continue
            }
            result.append(jump)
        }
        return result
    }

    private func editorJumpPoint(at crossing: CGPoint, on points: [CGPoint]) -> FlowEditorRouteJump? {
        guard points.count >= 2 else { return nil }
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            if abs(start.y - end.y) < 0.5 {
                let minX = min(start.x, end.x)
                let maxX = max(start.x, end.x)
                if crossing.y >= start.y - 0.5, crossing.y <= start.y + 0.5,
                   crossing.x >= minX + 2, crossing.x <= maxX - 2 {
                    return FlowEditorRouteJump(point: crossing, isHorizontal: true)
                }
            } else if abs(start.x - end.x) < 0.5 {
                let minY = min(start.y, end.y)
                let maxY = max(start.y, end.y)
                if crossing.x >= start.x - 0.5, crossing.x <= start.x + 0.5,
                   crossing.y >= minY + 2, crossing.y <= maxY - 2 {
                    return FlowEditorRouteJump(point: crossing, isHorizontal: false)
                }
            }
        }
        return nil
    }

    private struct FlowEditorRoutePairMetrics {
        var crossings: Int
        var overlaps: Int
    }

    private func editorRoutePairMetrics(pointsA: [CGPoint], pointsB: [CGPoint]) -> FlowEditorRoutePairMetrics {
        guard pointsA.count >= 2, pointsB.count >= 2 else {
            return .init(crossings: 0, overlaps: 0)
        }
        var crossings = 0
        var overlaps = 0
        for indexA in 0..<(pointsA.count - 1) {
            let a0 = pointsA[indexA]
            let a1 = pointsA[indexA + 1]
            for indexB in 0..<(pointsB.count - 1) {
                let b0 = pointsB[indexB]
                let b1 = pointsB[indexB + 1]

                if let crossing = editorSegmentCrossingPoint(a0: a0, a1: a1, b0: b0, b1: b1) {
                    let ignoreAtEnds =
                        (hypot(crossing.x - a0.x, crossing.y - a0.y) < 1.5)
                        || (hypot(crossing.x - a1.x, crossing.y - a1.y) < 1.5)
                        || (hypot(crossing.x - b0.x, crossing.y - b0.y) < 1.5)
                        || (hypot(crossing.x - b1.x, crossing.y - b1.y) < 1.5)
                    if !ignoreAtEnds {
                        crossings += 1
                    }
                }

                if editorSegmentsOverlap(a0: a0, a1: a1, b0: b0, b1: b1) {
                    overlaps += 1
                }
            }
        }
        return .init(crossings: crossings, overlaps: overlaps)
    }

    private func editorRouteCrossings(pointsA: [CGPoint], pointsB: [CGPoint]) -> [CGPoint] {
        guard pointsA.count >= 2, pointsB.count >= 2 else { return [] }
        var points: [CGPoint] = []
        for indexA in 0..<(pointsA.count - 1) {
            let a0 = pointsA[indexA]
            let a1 = pointsA[indexA + 1]
            for indexB in 0..<(pointsB.count - 1) {
                let b0 = pointsB[indexB]
                let b1 = pointsB[indexB + 1]
                if let crossing = editorSegmentCrossingPoint(a0: a0, a1: a1, b0: b0, b1: b1) {
                    points.append(crossing)
                }
            }
        }
        return points
    }

    private func editorSegmentCrossingPoint(
        a0: CGPoint,
        a1: CGPoint,
        b0: CGPoint,
        b1: CGPoint
    ) -> CGPoint? {
        let aHorizontal = abs(a0.y - a1.y) < 0.5
        let aVertical = abs(a0.x - a1.x) < 0.5
        let bHorizontal = abs(b0.y - b1.y) < 0.5
        let bVertical = abs(b0.x - b1.x) < 0.5

        if aHorizontal && bVertical {
            let x = b0.x
            let y = a0.y
            if x >= min(a0.x, a1.x), x <= max(a0.x, a1.x),
               y >= min(b0.y, b1.y), y <= max(b0.y, b1.y) {
                return CGPoint(x: x, y: y)
            }
        } else if aVertical && bHorizontal {
            let x = a0.x
            let y = b0.y
            if x >= min(b0.x, b1.x), x <= max(b0.x, b1.x),
               y >= min(a0.y, a1.y), y <= max(a0.y, a1.y) {
                return CGPoint(x: x, y: y)
            }
        }
        return nil
    }

    private func editorSegmentsOverlap(
        a0: CGPoint,
        a1: CGPoint,
        b0: CGPoint,
        b1: CGPoint
    ) -> Bool {
        if abs(a0.y - a1.y) < 0.5, abs(b0.y - b1.y) < 0.5, abs(a0.y - b0.y) < 0.5 {
            let minA = min(a0.x, a1.x)
            let maxA = max(a0.x, a1.x)
            let minB = min(b0.x, b1.x)
            let maxB = max(b0.x, b1.x)
            let overlap = min(maxA, maxB) - max(minA, minB)
            return overlap > 2
        }
        if abs(a0.x - a1.x) < 0.5, abs(b0.x - b1.x) < 0.5, abs(a0.x - b0.x) < 0.5 {
            let minA = min(a0.y, a1.y)
            let maxA = max(a0.y, a1.y)
            let minB = min(b0.y, b1.y)
            let maxB = max(b0.y, b1.y)
            let overlap = min(maxA, maxB) - max(minA, minB)
            return overlap > 2
        }
        return false
    }

    private func editorRoute(
        for edge: FlowEditorCanvasEdge,
        nodeRects: [String: CGRect],
        fallbackFrom: CGPoint,
        fallbackTo: CGPoint,
        existingRoutes: [[CGPoint]]
    ) -> FlowEditorEdgeRoute {
        guard let fromRect = nodeRects[edge.fromID], let toRect = nodeRects[edge.toID] else {
            let points = [fallbackFrom, fallbackTo]
            return FlowEditorEdgeRoute(
                points: points,
                labelPosition: editorLabelPosition(for: points)
            )
        }

        let fromAnchor = editorAnchorPoint(
            for: fromRect,
            side: edge.sourceSide,
            slot: edge.sourceSlot,
            slotCount: edge.sourceSlotCount
        )
        let toAnchor = editorAnchorPoint(
            for: toRect,
            side: edge.targetSide,
            slot: edge.targetSlot,
            slotCount: edge.targetSlotCount
        )

        let isBackEdge = edge.sourceSide == .north
            && edge.targetSide == .south
            && edge.semantic != .wait
        let worldMinY = nodeRects.values.map(\.minY).min() ?? min(fromAnchor.y, toAnchor.y)
        let worldMaxY = nodeRects.values.map(\.maxY).max() ?? max(fromAnchor.y, toAnchor.y)
        let shift = CGFloat(max(edge.sourceSlot, edge.targetSlot)) * 20
        let escapeDistance: CGFloat = 42 + shift * 0.45
        let fromEscape = editorEscapePoint(anchor: fromAnchor, side: edge.sourceSide, distance: escapeDistance)
        let toEscape = editorEscapePoint(anchor: toAnchor, side: edge.targetSide, distance: escapeDistance)
        let midX = (fromEscape.x + toEscape.x) / 2
        let midY = (fromEscape.y + toEscape.y) / 2

        let obstacles = nodeRects.compactMap { id, rect -> CGRect? in
            guard id != edge.fromID, id != edge.toID else { return nil }
            return rect.insetBy(dx: -12, dy: -8)
        }

        var candidates: [[CGPoint]] = [
            [
                fromAnchor,
                fromEscape,
                CGPoint(x: midX, y: fromEscape.y),
                CGPoint(x: midX, y: toEscape.y),
                toEscape,
                toAnchor
            ],
            [
                fromAnchor,
                fromEscape,
                CGPoint(x: fromEscape.x, y: toEscape.y),
                toEscape,
                toAnchor
            ],
            [
                fromAnchor,
                fromEscape,
                CGPoint(x: toEscape.x, y: fromEscape.y),
                toEscape,
                toAnchor
            ],
            [
                fromAnchor,
                fromEscape,
                CGPoint(x: fromEscape.x, y: midY),
                CGPoint(x: toEscape.x, y: midY),
                toEscape,
                toAnchor
            ]
        ]

        let useTopLane = edge.semantic == .wait || isBackEdge
        let useBottomLane = edge.semantic == .fail || edge.semantic == .parseError
        if useTopLane || useBottomLane {
            let laneBaseY = useTopLane
                ? worldMinY - (96 + shift * 0.52)
                : worldMaxY + (96 + shift * 0.52)
            candidates.append([
                fromAnchor,
                fromEscape,
                CGPoint(x: fromEscape.x, y: laneBaseY),
                CGPoint(x: toEscape.x, y: laneBaseY),
                toEscape,
                toAnchor
            ])
            candidates.append([
                fromAnchor,
                fromEscape,
                CGPoint(x: fromEscape.x, y: laneBaseY),
                CGPoint(x: midX, y: laneBaseY),
                CGPoint(x: toEscape.x, y: laneBaseY),
                toEscape,
                toAnchor
            ])
        }

        let points = editorBestRoute(
            candidates: candidates,
            obstacles: obstacles,
            existingRoutes: existingRoutes
        )
        return FlowEditorEdgeRoute(
            points: points,
            labelPosition: editorLabelPosition(for: points)
        )
    }

    private func editorEscapePoint(anchor: CGPoint, side: FlowEditorPortSide, distance: CGFloat) -> CGPoint {
        switch side {
        case .north:
            return CGPoint(x: anchor.x, y: anchor.y - distance)
        case .east:
            return CGPoint(x: anchor.x + distance, y: anchor.y)
        case .south:
            return CGPoint(x: anchor.x, y: anchor.y + distance)
        case .west:
            return CGPoint(x: anchor.x - distance, y: anchor.y)
        }
    }

    private func editorAnchorPoint(
        for rect: CGRect,
        side: FlowEditorPortSide,
        slot: Int,
        slotCount: Int
    ) -> CGPoint {
        let safeCount = max(slotCount, 1)
        let centerIndex = (CGFloat(safeCount) - 1) / 2
        let rawOffset = (CGFloat(slot) - centerIndex) * 12

        switch side {
        case .east:
            let maxYOffset = max((rect.height / 2) - 14, 0)
            let yOffset = min(max(rawOffset, -maxYOffset), maxYOffset)
            return CGPoint(x: rect.maxX + 8, y: rect.midY + yOffset)
        case .west:
            let maxYOffset = max((rect.height / 2) - 14, 0)
            let yOffset = min(max(rawOffset, -maxYOffset), maxYOffset)
            return CGPoint(x: rect.minX - 8, y: rect.midY + yOffset)
        case .north:
            let maxXOffset = max((rect.width / 2) - 16, 0)
            let xOffset = min(max(rawOffset, -maxXOffset), maxXOffset)
            return CGPoint(x: rect.midX + xOffset, y: rect.minY - 8)
        case .south:
            let maxXOffset = max((rect.width / 2) - 16, 0)
            let xOffset = min(max(rawOffset, -maxXOffset), maxXOffset)
            return CGPoint(x: rect.midX + xOffset, y: rect.maxY + 8)
        }
    }

    private func editorBestRoute(
        candidates: [[CGPoint]],
        obstacles: [CGRect],
        existingRoutes: [[CGPoint]]
    ) -> [CGPoint] {
        struct ScoredRoute {
            var points: [CGPoint]
            var intersections: Int
            var crossings: Int
            var overlaps: Int
            var turns: Int
            var length: CGFloat
        }

        var scoredRoutes: [ScoredRoute] = []
        for candidate in candidates {
            let points = editorSimplifyOrthogonalPoints(candidate)
            guard points.count >= 2 else { continue }
            let intersections = editorRouteIntersectionCount(points: points, obstacles: obstacles)
            var routeCrossings = 0
            var routeOverlaps = 0
            for existing in existingRoutes {
                let metrics = editorRoutePairMetrics(pointsA: points, pointsB: existing)
                routeCrossings += metrics.crossings
                routeOverlaps += metrics.overlaps
            }
            scoredRoutes.append(
                ScoredRoute(
                    points: points,
                    intersections: intersections,
                    crossings: routeCrossings,
                    overlaps: routeOverlaps,
                    turns: max(points.count - 2, 0),
                    length: editorPolylineLength(points)
                )
            )
        }

        guard !scoredRoutes.isEmpty else {
            return editorSimplifyOrthogonalPoints(candidates.first ?? [])
        }

        // Hard constraint: if any route can avoid all node obstacles, never choose a penetrating route.
        let hasNonPenetrating = scoredRoutes.contains { $0.intersections == 0 }
        let preferredRoutes = hasNonPenetrating
            ? scoredRoutes.filter { $0.intersections == 0 }
            : scoredRoutes

        let bestRoute = preferredRoutes.min { lhs, rhs in
            if lhs.intersections != rhs.intersections { return lhs.intersections < rhs.intersections }
            if lhs.crossings != rhs.crossings { return lhs.crossings < rhs.crossings }
            if lhs.overlaps != rhs.overlaps { return lhs.overlaps < rhs.overlaps }
            if lhs.turns != rhs.turns { return lhs.turns < rhs.turns }
            return lhs.length < rhs.length
        }

        return bestRoute?.points ?? editorSimplifyOrthogonalPoints(candidates.first ?? [])
    }

    private func editorRouteIntersectionCount(points: [CGPoint], obstacles: [CGRect]) -> Int {
        guard points.count >= 2 else { return 0 }
        var hitCount = 0
        for rect in obstacles {
            var intersects = false
            for segmentIndex in 0..<(points.count - 1) {
                let start = points[segmentIndex]
                let end = points[segmentIndex + 1]
                if editorSegmentIntersectsNode(start: start, end: end, rect: rect) {
                    intersects = true
                    break
                }
            }
            if intersects {
                hitCount += 1
            }
        }
        return hitCount
    }

    private func editorPolylineLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var length: CGFloat = 0
        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            length += hypot(end.x - start.x, end.y - start.y)
        }
        return length
    }

    private func editorSegmentIntersectsNode(start: CGPoint, end: CGPoint, rect: CGRect) -> Bool {
        if abs(start.y - end.y) < 0.5 {
            let y = start.y
            guard y >= rect.minY, y <= rect.maxY else { return false }
            let minX = min(start.x, end.x)
            let maxX = max(start.x, end.x)
            return maxX >= rect.minX && minX <= rect.maxX
        }
        if abs(start.x - end.x) < 0.5 {
            let x = start.x
            guard x >= rect.minX, x <= rect.maxX else { return false }
            let minY = min(start.y, end.y)
            let maxY = max(start.y, end.y)
            return maxY >= rect.minY && minY <= rect.maxY
        }
        return rect.intersects(CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        ))
    }

    private func editorSimplifyOrthogonalPoints(_ points: [CGPoint]) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        var uniquePoints: [CGPoint] = []
        for point in points {
            if let last = uniquePoints.last, hypot(last.x - point.x, last.y - point.y) < 0.5 {
                continue
            }
            uniquePoints.append(point)
        }
        guard uniquePoints.count >= 3 else { return uniquePoints }

        var simplified: [CGPoint] = [uniquePoints[0]]
        for index in 1..<(uniquePoints.count - 1) {
            let prev = simplified.last ?? uniquePoints[index - 1]
            let current = uniquePoints[index]
            let next = uniquePoints[index + 1]
            let vertical = abs(prev.x - current.x) < 0.5 && abs(current.x - next.x) < 0.5
            let horizontal = abs(prev.y - current.y) < 0.5 && abs(current.y - next.y) < 0.5
            if vertical || horizontal {
                continue
            }
            simplified.append(current)
        }
        if let last = uniquePoints.last {
            simplified.append(last)
        }
        return simplified
    }

    private func roundedOrthogonalPath(points: [CGPoint], cornerRadius: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        guard points.count > 2 else {
            path.addLine(to: points[1])
            return path
        }

        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]

            let v1x = current.x - previous.x
            let v1y = current.y - previous.y
            let v2x = next.x - current.x
            let v2y = next.y - current.y
            let len1 = hypot(v1x, v1y)
            let len2 = hypot(v2x, v2y)
            guard len1 > 0.1, len2 > 0.1 else {
                path.addLine(to: current)
                continue
            }

            let cross = v1x * v2y - v1y * v2x
            guard abs(cross) > 0.5 else {
                path.addLine(to: current)
                continue
            }

            let radius = min(cornerRadius, len1 / 2, len2 / 2)
            let entry = CGPoint(
                x: current.x - (v1x / len1) * radius,
                y: current.y - (v1y / len1) * radius
            )
            let exit = CGPoint(
                x: current.x + (v2x / len2) * radius,
                y: current.y + (v2y / len2) * radius
            )

            path.addLine(to: entry)
            path.addQuadCurve(to: exit, control: current)
        }

        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }

    private func editorArrowHeadPath(for points: [CGPoint], size: CGFloat = 8) -> Path {
        guard points.count >= 2 else { return Path() }
        let tip = points[points.count - 1]

        var previous = points[points.count - 2]
        var vector = CGVector(dx: tip.x - previous.x, dy: tip.y - previous.y)
        var length = hypot(vector.dx, vector.dy)

        if length < 0.5 {
            for index in stride(from: points.count - 3, through: 0, by: -1) {
                previous = points[index]
                vector = CGVector(dx: tip.x - previous.x, dy: tip.y - previous.y)
                length = hypot(vector.dx, vector.dy)
                if length >= 0.5 {
                    break
                }
            }
        }

        guard length >= 0.5 else { return Path() }

        let unit = CGVector(dx: vector.dx / length, dy: vector.dy / length)
        let baseCenter = CGPoint(
            x: tip.x - unit.dx * size * 1.15,
            y: tip.y - unit.dy * size * 1.15
        )
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)
        let wing = size * 0.62
        let left = CGPoint(
            x: baseCenter.x + normal.dx * wing,
            y: baseCenter.y + normal.dy * wing
        )
        let right = CGPoint(
            x: baseCenter.x - normal.dx * wing,
            y: baseCenter.y - normal.dy * wing
        )

        var path = Path()
        path.move(to: tip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        return path
    }

    private func editorLabelPosition(for points: [CGPoint]) -> CGPoint {
        guard points.count >= 2 else { return .zero }
        var segmentIndex = 0
        var segmentLength: CGFloat = 0
        while segmentIndex < points.count - 1 {
            let start = points[segmentIndex]
            let end = points[segmentIndex + 1]
            segmentLength = hypot(end.x - start.x, end.y - start.y)
            if segmentLength >= 28 || segmentIndex == points.count - 2 {
                break
            }
            segmentIndex += 1
        }

        let start = points[segmentIndex]
        let end = points[segmentIndex + 1]
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let isVertical = abs(start.x - end.x) < abs(start.y - end.y)

        if isVertical {
            return CGPoint(x: mid.x + 24, y: mid.y)
        }
        return CGPoint(x: mid.x, y: mid.y - 12)
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

    private func setEditorCanvasZoom(_ value: CGFloat) {
        editorCanvasZoom = min(max(value, editorCanvasMinZoom), editorCanvasMaxZoom)
    }

    private func adjustEditorCanvasZoom(by delta: CGFloat) {
        setEditorCanvasZoom(editorCanvasZoom + delta)
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
        guard decoded.version == 3 else {
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
        let stateIDs = Set(definition.states.map(\.id))
        var incoming: [String: [(from: String, label: String)]] = [:]
        var outgoing: [String: [(label: String, target: String)]] = [:]
        for state in definition.states {
            let edges = editorTargets(for: state).filter { stateIDs.contains($0.target) }
            outgoing[state.id] = edges
            for edge in edges {
                incoming[edge.target, default: []].append((from: state.id, label: edge.label))
            }
        }

        let mainPath = editorMainPath(start: definition.start, stateMap: stateMap, stateIDs: stateIDs)
        let mainPathSet = Set(mainPath)
        let endIDs = definition.states.filter { $0.type == .end }.map(\.id)

        var rank: [String: Int] = [:]
        for (index, id) in mainPath.enumerated() {
            rank[id] = index
        }
        var unresolved = stateIDs.subtracting(rank.keys)
        var safety = 0
        while !unresolved.isEmpty, safety < max(1, definition.states.count * 5) {
            safety += 1
            var progressed = false
            for id in Array(unresolved) {
                let parentRanks = incoming[id, default: []].compactMap { rank[$0.from] }
                guard !parentRanks.isEmpty else { continue }
                rank[id] = (parentRanks.max() ?? 0) + 1
                unresolved.remove(id)
                progressed = true
            }
            if !progressed {
                break
            }
        }
        if !unresolved.isEmpty {
            let spillStart = (rank.values.max() ?? 0) + 1
            for (offset, id) in unresolved.sorted().enumerated() {
                rank[id] = spillStart + offset
            }
        }

        let terminalRank = (rank.values.max() ?? 0) + 1
        for id in endIDs {
            rank[id] = terminalRank
        }

        var lane: [String: Int] = [:]
        for id in mainPath {
            lane[id] = 0
        }
        for state in definition.states where lane[state.id] == nil {
            let incomingLabels = Set(incoming[state.id, default: []].map(\.label))
            let outgoingLabels = Set(outgoing[state.id, default: []].map(\.label))
            let laneValue: Int
            if state.type == .wait || incomingLabels.contains("wait") || outgoingLabels.contains("wait") {
                laneValue = -2
            } else if state.type == .end {
                laneValue = 0
            } else if incomingLabels.contains("fail")
                || incomingLabels.contains("parse_error")
                || outgoingLabels.contains("fail")
                || outgoingLabels.contains("parse_error") {
                laneValue = 2
            } else if incomingLabels.contains("pass") {
                laneValue = -1
            } else if incomingLabels.contains("needs_agent") {
                laneValue = 1
            } else {
                laneValue = 1
            }
            lane[state.id] = laneValue
        }

        let baseX: CGFloat = 190
        let baseY: CGFloat = 300
        let rankStep: CGFloat = 300
        let laneStep: CGFloat = 170
        let stackStep: CGFloat = 96
        let terminalX = baseX + CGFloat(terminalRank) * rankStep

        func barycenter(_ id: String) -> Double {
            let parents = incoming[id, default: []]
            let values = parents.compactMap { edge -> Double? in
                guard let parentRank = rank[edge.from],
                      let parentLane = lane[edge.from] else {
                    return nil
                }
                return Double(parentLane * 100 + parentRank)
            }
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }

        func assignStackedIDs(
            _ ids: [String],
            x: CGFloat,
            baseY: CGFloat,
            stackStep: CGFloat,
            into centers: inout [String: CGPoint]
        ) {
            let offsets = editorSymmetricOffsets(count: ids.count)
            for (index, id) in ids.enumerated() {
                centers[id] = CGPoint(
                    x: x,
                    y: baseY + CGFloat(offsets[index]) * stackStep
                )
            }
        }

        var centers: [String: CGPoint] = [:]
        for (index, id) in mainPath.enumerated() {
            centers[id] = CGPoint(
                x: baseX + CGFloat(index) * rankStep,
                y: baseY
            )
        }

        var grouped: [Int: [Int: [String]]] = [:]
        for state in definition.states where !mainPathSet.contains(state.id) && !endIDs.contains(state.id) {
            let rankValue = rank[state.id] ?? 0
            let laneValue = lane[state.id] ?? 1
            grouped[rankValue, default: [:]][laneValue, default: []].append(state.id)
        }

        for rankValue in grouped.keys.sorted() {
            guard let laneGroups = grouped[rankValue] else { continue }
            for laneValue in laneGroups.keys.sorted() {
                let ids = laneGroups[laneValue, default: []].sorted { lhs, rhs in
                    let b0 = barycenter(lhs)
                    let b1 = barycenter(rhs)
                    if abs(b0 - b1) > 0.001 {
                        return b0 < b1
                    }
                    return lhs < rhs
                }
                assignStackedIDs(
                    ids,
                    x: baseX + CGFloat(rankValue) * rankStep,
                    baseY: baseY + CGFloat(laneValue) * laneStep,
                    stackStep: stackStep,
                    into: &centers
                )
            }
        }

        let successEnds = definition.states
            .filter { $0.type == .end && $0.endStatus == .success }
            .map(\.id)
            .sorted()
        let failureEnds = definition.states
            .filter { $0.type == .end && $0.endStatus == .failure }
            .map(\.id)
            .sorted()
        let remainingEnds = endIDs
            .filter { !successEnds.contains($0) && !failureEnds.contains($0) }
            .sorted()

        assignStackedIDs(
            successEnds,
            x: terminalX,
            baseY: baseY - laneStep * 0.9,
            stackStep: 78,
            into: &centers
        )
        assignStackedIDs(
            failureEnds,
            x: terminalX,
            baseY: baseY + laneStep * 0.9,
            stackStep: 78,
            into: &centers
        )
        assignStackedIDs(
            remainingEnds,
            x: terminalX,
            baseY: baseY,
            stackStep: 78,
            into: &centers
        )

        if centers.count < definition.states.count {
            let fallbackX = (centers.values.map(\.x).max() ?? baseX) + rankStep
            var spill = 0
            for state in definition.states where centers[state.id] == nil {
                centers[state.id] = CGPoint(
                    x: fallbackX,
                    y: baseY + CGFloat(spill) * stackStep
                )
                spill += 1
            }
        }

        return centers
    }

    private func editorSymmetricOffsets(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for index in 0..<count {
            if index == 0 {
                offsets.append(0)
                continue
            }
            let magnitude = (index + 1) / 2
            offsets.append(index.isMultiple(of: 2) ? magnitude : -magnitude)
        }
        return offsets
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
