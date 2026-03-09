import SwiftUI
import ScriptoriaCore

/// Shows all schedules across all scripts
struct AllSchedulesView: View {
    @EnvironmentObject var appState: AppState

    var sortedSchedules: [Schedule] {
        appState.schedules.sorted { a, b in
            if a.isEnabled != b.isEnabled { return a.isEnabled }
            return (a.nextRunAt ?? .distantFuture) < (b.nextRunAt ?? .distantFuture)
        }
    }

    var body: some View {
        List {
            if appState.schedules.isEmpty {
                ContentUnavailableView {
                    Label("No Schedules", systemImage: "clock")
                } description: {
                    Text("Add a schedule from a script's detail view")
                }
            } else {
                // Active
                let active = sortedSchedules.filter(\.isEnabled)
                if !active.isEmpty {
                    Section {
                        ForEach(active) { schedule in
                            AllScheduleRow(schedule: schedule)
                        }
                    } header: {
                        Label("Active (\(active.count))", systemImage: "bolt.fill")
                    }
                }

                // Inactive
                let inactive = sortedSchedules.filter { !$0.isEnabled }
                if !inactive.isEmpty {
                    Section {
                        ForEach(inactive) { schedule in
                            AllScheduleRow(schedule: schedule)
                        }
                    } header: {
                        Label("Paused (\(inactive.count))", systemImage: "pause.circle")
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

struct AllScheduleRow: View {
    let schedule: Schedule
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false

    var script: Script? {
        appState.scripts.first { $0.id == schedule.scriptId }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Toggle
            Button {
                Task { await appState.toggleSchedule(schedule) }
            } label: {
                ZStack {
                    Circle()
                        .fill(schedule.isEnabled ? AnyShapeStyle(Theme.successColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.3)))
                        .frame(width: 28, height: 28)
                    Image(systemName: schedule.isEnabled ? "checkmark" : "pause")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(schedule.isEnabled ? Theme.successColor : .secondary)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(script?.title ?? "Unknown Script")
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Label(schedule.type.displayText, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let next = schedule.nextRunAt, schedule.isEnabled {
                        Text("Next: \(next.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            let installed = LaunchdHelper.isInstalled(scheduleId: schedule.id)
            HStack(spacing: 4) {
                StatusDot(color: installed ? Theme.successColor : .gray, size: 6)
                Text(installed ? "Active" : "Inactive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(schedule.isEnabled ? "Disable" : "Enable") {
                Task { await appState.toggleSchedule(schedule) }
            }
            Divider()
            Button("Remove", role: .destructive) {
                Task { await appState.removeSchedule(schedule) }
            }
        }
    }
}
