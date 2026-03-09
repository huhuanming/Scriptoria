import SwiftUI
import ScriptoriaCore

/// Main application window with three-column layout
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            if appState.selectedTag == "__schedules__" {
                AllSchedulesView()
            } else {
                ScriptListView()
            }
        } detail: {
            if let script = appState.selectedScript {
                ScriptDetailView(script: script)
            } else {
                EmptyDetailView()
            }
        }
        .searchable(text: $appState.searchQuery, prompt: "Search scripts...")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add script")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddScriptSheet(isPresented: $showAddSheet)
                .environmentObject(appState)
        }
        .task {
            await appState.loadScripts()
        }
    }
}

/// Sidebar with tags and categories
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedTag) {
            Section("Library") {
                Label("All Scripts", systemImage: "list.bullet")
                    .tag(nil as String?)
                    .onTapGesture { appState.selectedTag = nil }

                Label("Favorites", systemImage: "star.fill")
                    .foregroundStyle(.yellow)
                    .tag("__favorites__" as String?)
                    .onTapGesture { appState.selectedTag = "__favorites__" }

                Label("Recent", systemImage: "clock")
                    .tag("__recent__" as String?)
                    .onTapGesture { appState.selectedTag = "__recent__" }
            }

            if !appState.schedules.isEmpty {
                Section("Schedules") {
                    Label("All Schedules", systemImage: "clock.arrow.circlepath")
                        .tag("__schedules__" as String?)
                }
            }

            if !appState.allTags.isEmpty {
                Section("Tags") {
                    ForEach(appState.allTags, id: \.self) { tag in
                        Label(tag, systemImage: "tag")
                            .tag(tag as String?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Scriptoria")
    }
}

/// Script list in the content column
struct ScriptListView: View {
    @EnvironmentObject var appState: AppState

    var scripts: [Script] {
        if appState.selectedTag == "__favorites__" {
            return appState.favoriteScripts
        }
        if appState.selectedTag == "__recent__" {
            return appState.recentScripts
        }
        return appState.filteredScripts
    }

    var body: some View {
        List(scripts, selection: Binding(
            get: { appState.selectedScript?.id },
            set: { id in appState.selectedScript = appState.scripts.first { $0.id == id } }
        )) { script in
            ScriptRowView(script: script)
                .tag(script.id)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if scripts.isEmpty {
                ContentUnavailableView {
                    Label("No Scripts", systemImage: "doc.text")
                } description: {
                    Text("Add scripts using the + button or the CLI")
                }
            }
        }
    }
}

/// Single script row in the list
struct ScriptRowView: View {
    let script: Script
    @EnvironmentObject var appState: AppState

    var isRunning: Bool {
        appState.runningScriptIds.contains(script.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 30, height: 30)
                if isRunning {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: statusIcon)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(script.title)
                        .fontWeight(.medium)
                    if script.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                if !script.description.isEmpty {
                    Text(script.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    ForEach(script.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.1), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            Text("×\(script.runCount)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Run") {
                Task { await appState.runScript(script) }
            }
            Button(script.isFavorite ? "Unfavorite" : "Favorite") {
                Task { await appState.toggleFavorite(script) }
            }
            Divider()
            Button("Remove", role: .destructive) {
                Task { await appState.removeScript(id: script.id) }
            }
        }
    }

    var statusIcon: String {
        switch script.lastRunStatus {
        case .success: return "checkmark"
        case .failure: return "xmark"
        case .running: return "play.fill"
        case .cancelled: return "stop.fill"
        case nil: return "minus"
        }
    }

    var statusColor: Color {
        switch script.lastRunStatus {
        case .success: return .green
        case .failure: return .red
        case .running: return .blue
        case .cancelled: return .orange
        case nil: return .gray
        }
    }
}

/// Empty state for the detail column
struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("Select a script")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}
