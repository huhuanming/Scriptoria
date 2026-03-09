import SwiftUI
import ScriptoriaCore

/// Detail view for a selected script
struct ScriptDetailView: View {
    let script: Script
    @EnvironmentObject var appState: AppState
    @State private var showEditSheet = false
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
                outputSection
            }
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
            .padding(.bottom, 16)
        }
    }

    // MARK: - Output

    var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Output", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                if !appState.currentOutput.isEmpty {
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
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if appState.currentOutput.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "text.page")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("Run the script to see output")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(appState.currentOutput)
                        .terminalOutput()
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 20)
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
