import SwiftUI
import ScriptoriaCore

/// The panel shown when clicking the menu bar icon
struct MenuBarPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

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
            HStack(spacing: 8) {
                // App icon
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accentGradient.opacity(0.2))
                        .frame(width: 26, height: 26)
                    Image(systemName: "terminal.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }

                Text("Scriptoria")
                    .font(.headline)

                Spacer()

                // Running count
                if !appState.runningScriptIds.isEmpty {
                    HStack(spacing: 3) {
                        StatusDot(color: Theme.runningColor, isAnimating: true, size: 6)
                        Text("\(appState.runningScriptIds.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.runningColor)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.runningColor.opacity(0.1), in: Capsule())
                }

                Button {
                    openWindow(id: "main")
                } label: {
                    Image(systemName: "macwindow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Open main window")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField("Search scripts...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !searchText.isEmpty {
                    Button {
                        withAnimation(Theme.fadeQuick) { searchText = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Script list
            if displayedScripts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: searchText.isEmpty ? "terminal" : "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text(searchText.isEmpty ? "No scripts yet" : "No results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if searchText.isEmpty {
                        Text("Use `scriptoria add` or the main window")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        // Favorites
                        if searchText.isEmpty && !appState.favoriteScripts.isEmpty {
                            SectionHeader(title: "Favorites", icon: "star.fill", iconColor: .yellow)
                            ForEach(appState.favoriteScripts) { script in
                                MenuBarScriptRow(script: script)
                            }
                            SectionHeader(title: "All Scripts", icon: "list.bullet")
                        }

                        ForEach(displayedScripts) { script in
                            MenuBarScriptRow(script: script)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 380)
            }

            Divider()

            // Footer
            HStack(spacing: 12) {
                Text("\(appState.scripts.count) scripts")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if !appState.schedules.filter(\.isEnabled).isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 7))
                        Text("\(appState.schedules.filter(\.isEnabled).count) active")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gear")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 330)
        .task {
            if appState.needsOnboarding {
                // Open the main window for onboarding
                openWindow(id: "main")
            } else {
                await appState.loadScripts()
            }
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var icon: String? = nil
    var iconColor: Color = .gray

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(iconColor)
            }
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }
}

// MARK: - Menu Bar Script Row

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
            // Status
            Group {
                if isRunning {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 18, height: 18)
                } else {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.12))
                            .frame(width: 18, height: 18)
                        Image(systemName: statusIcon)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(statusColor)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(script.title)
                        .font(.body)
                        .lineLimit(1)
                    if hasSchedule {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Theme.runningColor.opacity(0.6))
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
                    Task { await appState.runScript(script) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Theme.fadeQuick) {
                isHovering = hovering
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
        case nil: return .gray.opacity(0.5)
        }
    }
}
