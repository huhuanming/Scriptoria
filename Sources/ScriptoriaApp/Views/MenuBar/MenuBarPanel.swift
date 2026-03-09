import SwiftUI
import ScriptoriaCore

/// The panel shown when clicking the menu bar icon
struct MenuBarPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @Environment(\.openWindow) private var openWindow

    var displayedScripts: [Script] {
        if searchText.isEmpty {
            return appState.scripts
        }
        let q = searchText.lowercased()
        return appState.scripts.filter {
            $0.title.lowercased().contains(q)
            || $0.description.lowercased().contains(q)
            || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.title3)
                    .foregroundStyle(.primary)
                Text("Scriptoria")
                    .font(.headline)
                Spacer()
                Button {
                    openWindow(id: "main")
                } label: {
                    Image(systemName: "macwindow")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open main window")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField("Search scripts...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Script list
            if displayedScripts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text(searchText.isEmpty ? "No scripts yet" : "No results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if searchText.isEmpty {
                        Text("Use `scriptoria add` or open the main window")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Favorites section
                        if searchText.isEmpty && !appState.favoriteScripts.isEmpty {
                            SectionHeader(title: "Favorites")
                            ForEach(appState.favoriteScripts) { script in
                                MenuBarScriptRow(script: script)
                            }
                            SectionHeader(title: "All Scripts")
                        }

                        ForEach(displayedScripts) { script in
                            MenuBarScriptRow(script: script)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
            }

            Divider()

            // Footer
            HStack {
                Text("\(appState.scripts.count) scripts")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Settings...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
        .task {
            await appState.loadScripts()
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

struct MenuBarScriptRow: View {
    let script: Script
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false

    var isRunning: Bool {
        appState.runningScriptIds.contains(script.id)
    }

    var hasSchedule: Bool {
        appState.schedules.contains { $0.scriptId == script.id && $0.isEnabled }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status icon
            Group {
                if isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: statusIcon)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .frame(width: 16, height: 16)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(script.title)
                        .font(.body)
                        .lineLimit(1)
                    if hasSchedule {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.blue.opacity(0.7))
                    }
                }
                if !script.description.isEmpty {
                    Text(script.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isHovering && !isRunning {
                Button {
                    Task {
                        await appState.runScript(script)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    var statusIcon: String {
        switch script.lastRunStatus {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .running: return "play.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case nil: return "circle"
        }
    }

    var statusColor: Color {
        switch script.lastRunStatus {
        case .success: return .green
        case .failure: return .red
        case .running: return .blue
        case .cancelled: return .orange
        case nil: return .gray.opacity(0.4)
        }
    }
}
