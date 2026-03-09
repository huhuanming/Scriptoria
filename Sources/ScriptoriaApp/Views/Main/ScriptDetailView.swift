import SwiftUI
import ScriptoriaCore

/// Detail view for a selected script
struct ScriptDetailView: View {
    let script: Script
    @EnvironmentObject var appState: AppState
    @State private var showEditSheet = false

    var isRunning: Bool {
        appState.runningScriptIds.contains(script.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                headerSection
                Divider()
                // Info
                infoSection
                Divider()
                // Schedules
                ScheduleSection(script: script)
                Divider()
                // Output
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
                }
                .help(script.isFavorite ? "Remove from favorites" : "Add to favorites")

                Button {
                    showEditSheet = true
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit script")

                Button {
                    Task { await appState.runScript(script) }
                } label: {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
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

    var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
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
                Spacer()
                // Run button
                Button {
                    Task { await appState.runScript(script) }
                } label: {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(isRunning ? "Running..." : "Run")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }

            // Tags
            if !script.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(script.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.1), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .padding(20)
    }

    var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            InfoRow(label: "Path", value: script.path, monospaced: true)
            InfoRow(label: "Interpreter", value: script.interpreter.rawValue)
            InfoRow(label: "Run Count", value: "\(script.runCount)")
            if let lastRun = script.lastRunAt {
                InfoRow(label: "Last Run", value: lastRun.formatted(.relative(presentation: .named)))
            }
            if let status = script.lastRunStatus {
                HStack {
                    Text("Last Status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .trailing)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(status == .success ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(status.rawValue)
                            .font(.body)
                    }
                }
            }
        }
        .padding(20)
    }

    var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            if appState.currentOutput.isEmpty {
                Text("Run the script to see output here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(appState.currentOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 20)
    }
}

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
