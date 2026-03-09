import SwiftUI
import ScriptoriaCore

/// Shows all schedules across all scripts
struct AllSchedulesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            if appState.schedules.isEmpty {
                ContentUnavailableView {
                    Label("No Schedules", systemImage: "clock")
                } description: {
                    Text("Add a schedule from a script's detail view")
                }
            } else {
                ForEach(appState.schedules) { schedule in
                    let script = appState.scripts.first { $0.id == schedule.scriptId }
                    HStack(spacing: 12) {
                        // Status
                        Image(systemName: schedule.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(schedule.isEnabled ? .green : .gray)
                            .font(.body)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(script?.title ?? "Unknown Script")
                                .fontWeight(.medium)
                            Text(schedule.type.displayText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let next = schedule.nextRunAt, schedule.isEnabled {
                                Text("Next: \(next.formatted(.relative(presentation: .named)))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()

                        // launchd indicator
                        let installed = LaunchdHelper.isInstalled(scheduleId: schedule.id)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(installed ? .green : .gray)
                                .frame(width: 6, height: 6)
                            Text(installed ? "Active" : "Inactive")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
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
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle("Schedules")
    }
}
