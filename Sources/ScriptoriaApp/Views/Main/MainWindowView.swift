import SwiftUI
import ScriptoriaCore

/// Main application window with three-column layout
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } content: {
            switch appState.selectedTag {
            case "__schedules__":
                AllSchedulesView()
            default:
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
            _ = await NotificationManager.shared.requestPermission()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedTag) {
            Section("Library") {
                sidebarItem("All Scripts", icon: "square.grid.2x2", tag: "__all__", count: appState.scripts.count)
                sidebarItem("Favorites", icon: "star.fill", tag: "__favorites__", count: appState.favoriteScripts.count, iconColor: .yellow)
                sidebarItem("Recent", icon: "clock.arrow.counterclockwise", tag: "__recent__", count: appState.recentScripts.count)
            }

            if !appState.schedules.isEmpty {
                Section("Automation") {
                    sidebarItem("Schedules", icon: "clock.arrow.circlepath", tag: "__schedules__", count: appState.schedules.filter(\.isEnabled).count, iconColor: Theme.runningColor)
                }
            }

            if !appState.allTags.isEmpty {
                Section("Tags") {
                    ForEach(appState.allTags, id: \.self) { tag in
                        Label {
                            HStack {
                                Text(tag)
                                Spacer()
                                Text("\(appState.scripts.filter { $0.tags.contains(tag) }.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: "tag.fill")
                                .foregroundStyle(Theme.tagColor(for: tag))
                                .font(.caption)
                        }
                        .tag(tag)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Scriptoria")
    }

    private func sidebarItem(_ title: String, icon: String, tag: String, count: Int, iconColor: Color? = nil) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(iconColor ?? .secondary)
        }
        .tag(tag)
    }
}

// MARK: - Script List

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
            set: { id in
                withAnimation(Theme.fadeQuick) {
                    appState.selectedScript = appState.scripts.first { $0.id == id }
                }
            }
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
                    Text("Add scripts using the + button or `scriptoria add`")
                }
            }
        }
    }
}

// MARK: - Script Row

struct ScriptRowView: View {
    let script: Script
    @EnvironmentObject var appState: AppState

    var isRunning: Bool {
        appState.runningScriptIds.contains(script.id)
    }

    var hasSchedule: Bool {
        appState.schedules.contains { $0.scriptId == script.id && $0.isEnabled }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                if isRunning {
                    ProgressView()
                        .scaleEffect(0.55)
                } else {
                    Image(systemName: statusIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(script.title)
                        .fontWeight(.medium)
                    if script.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if hasSchedule {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.runningColor.opacity(0.7))
                    }
                }
                if !script.description.isEmpty {
                    Text(script.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !script.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(script.tags.prefix(4), id: \.self) { tag in
                            TagCapsule(tag: tag, isCompact: true)
                        }
                        if script.tags.count > 4 {
                            Text("+\(script.tags.count - 4)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(script.runCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let lastRun = script.lastRunAt {
                    Text(lastRun, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button { Task { await appState.runScript(script) } } label: {
                Label("Run", systemImage: "play.fill")
            }
            Button { Task { await appState.toggleFavorite(script) } } label: {
                Label(script.isFavorite ? "Unfavorite" : "Favorite", systemImage: script.isFavorite ? "star.slash" : "star")
            }
            Divider()
            Button(role: .destructive) { Task { await appState.removeScript(id: script.id) } } label: {
                Label("Remove", systemImage: "trash")
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
        case .success: return Theme.successColor
        case .failure: return Theme.failureColor
        case .running: return Theme.runningColor
        case .cancelled: return Theme.warningColor
        case nil: return .gray
        }
    }
}

// MARK: - Empty Detail

struct EmptyDetailView: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.quaternary.opacity(0.3))
                    .frame(width: 80, height: 80)
                Image(systemName: "terminal")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text("Select a script")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Choose a script from the list to view details and run it")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
