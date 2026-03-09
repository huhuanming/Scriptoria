import SwiftUI
import ScriptoriaCore

/// Detail view for a selected script
struct ScriptDetailView: View {
    let script: Script
    @EnvironmentObject var appState: AppState
    @State private var showEditSheet = false
    @State private var runHistory: [ScriptRun] = []
    @State private var selectedRun: ScriptRun?
    @Environment(\.colorScheme) var colorScheme

    var isRunning: Bool {
        appState.runningScriptIds.contains(script.id)
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
        }
        .onChange(of: appState.currentOutput) { _, _ in
            loadHistory()
        }
        .onAppear { loadHistory() }
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

                Button {
                    Task { await appState.runScript(script) }
                } label: {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(isRunning ? "Running..." : "Run script")
                .disabled(isRunning)
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

                // Run button
                Button {
                    Task { await appState.runScript(script) }
                } label: {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(isRunning ? "Running..." : "Run")
                    }
                }
                .buttonStyle(RunButtonStyle(isRunning: isRunning))
                .disabled(isRunning)
            }

            // Tags
            if !script.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(script.tags, id: \.self) { tag in
                        TagCapsule(tag: tag)
                    }
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
                    icon: interpreterIcon,
                    label: "Interpreter",
                    value: script.interpreter.rawValue,
                    color: Theme.accent
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

                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(appState.currentOutput)
                            .terminalOutput()
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
