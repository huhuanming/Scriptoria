import SwiftUI
import ScriptoriaCore

/// Schedule management section within ScriptDetailView
struct ScheduleSection: View {
    let script: Script
    @EnvironmentObject var appState: AppState
    @State private var showAddSchedule = false

    var schedules: [Schedule] {
        appState.schedulesForScript(script.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Schedules")
                    .font(.headline)
                Spacer()
                Button {
                    showAddSchedule = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Add schedule")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if schedules.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("No schedules")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(schedules) { schedule in
                        ScheduleRow(schedule: schedule)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .sheet(isPresented: $showAddSchedule) {
            AddScheduleSheet(script: script, isPresented: $showAddSchedule)
                .environmentObject(appState)
        }
    }
}

/// Single schedule row
struct ScheduleRow: View {
    let schedule: Schedule
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await appState.toggleSchedule(schedule)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(schedule.isEnabled ? AnyShapeStyle(Theme.successColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.3)))
                        .frame(width: 24, height: 24)
                    Image(systemName: schedule.isEnabled ? "checkmark" : "pause")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(schedule.isEnabled ? Theme.successColor : .secondary)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.type.displayText)
                    .font(.callout)
                    .foregroundStyle(schedule.isEnabled ? .primary : .secondary)

                if let next = schedule.nextRunAt, schedule.isEnabled {
                    Text("Next: \(next.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            let installed = LaunchdHelper.isInstalled(scheduleId: schedule.id)
            StatusDot(color: installed ? Theme.successColor : .gray, size: 6)
                .help(installed ? "Active in launchd" : "Not active")

            if isHovering {
                Button {
                    Task { await appState.removeSchedule(schedule) }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(Theme.failureColor)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.quaternary.opacity(0.15)))
        )
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(Theme.fadeQuick) { isHovering = h }
        }
    }
}

/// Sheet for adding a new schedule
struct AddScheduleSheet: View {
    let script: Script
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState

    enum ScheduleMode: String, CaseIterable {
        case interval = "Interval"
        case daily = "Daily"
        case weekly = "Weekly"
    }

    @State private var mode: ScheduleMode = .daily
    @State private var intervalMinutes: Int = 30
    @State private var dailyHour: Int = 9
    @State private var dailyMinute: Int = 0
    @State private var weeklyHour: Int = 9
    @State private var weeklyMinute: Int = 0
    @State private var selectedDays: Set<Int> = [2, 3, 4, 5, 6] // Mon-Fri

    let dayNames = [(1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat")]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Schedule")
                    .font(.headline)
                Spacer()
                Text(script.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            Form {
                Picker("Type", selection: $mode) {
                    ForEach(ScheduleMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .interval:
                    HStack {
                        Text("Run every")
                        TextField("", value: $intervalMinutes, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text("minutes")
                    }
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .daily:
                    HStack {
                        Text("Time")
                        Picker("Hour", selection: $dailyHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d", h)).tag(h)
                            }
                        }
                        .frame(width: 70)
                        Text(":")
                        Picker("Minute", selection: $dailyMinute) {
                            ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                                Text(String(format: "%02d", m)).tag(m)
                            }
                        }
                        .frame(width: 70)
                    }
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .weekly:
                    HStack {
                        Text("Time")
                        Picker("Hour", selection: $weeklyHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d", h)).tag(h)
                            }
                        }
                        .frame(width: 70)
                        Text(":")
                        Picker("Minute", selection: $weeklyMinute) {
                            ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                                Text(String(format: "%02d", m)).tag(m)
                            }
                        }
                        .frame(width: 70)
                    }

                    HStack(spacing: 6) {
                        ForEach(dayNames, id: \.0) { day in
                            Button {
                                if selectedDays.contains(day.0) {
                                    selectedDays.remove(day.0)
                                } else {
                                    selectedDays.insert(day.0)
                                }
                            } label: {
                                Text(day.1)
                                    .font(.caption)
                                    .frame(width: 36, height: 28)
                                    .background(
                                        selectedDays.contains(day.0)
                                            ? AnyShapeStyle(.blue)
                                            : AnyShapeStyle(.quaternary),
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .foregroundStyle(selectedDays.contains(day.0) ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 4)

            Divider()

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Schedule") {
                    Task {
                        await appState.addSchedule(scriptId: script.id, type: scheduleType)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 440, height: 340)
    }

    var scheduleType: ScheduleType {
        switch mode {
        case .interval:
            return .interval(TimeInterval(intervalMinutes * 60))
        case .daily:
            return .daily(hour: dailyHour, minute: dailyMinute)
        case .weekly:
            return .weekly(weekdays: Array(selectedDays).sorted(), hour: weeklyHour, minute: weeklyMinute)
        }
    }

    var isValid: Bool {
        switch mode {
        case .interval: return intervalMinutes > 0
        case .daily: return true
        case .weekly: return !selectedDays.isEmpty
        }
    }

    var previewText: String {
        scheduleType.displayText
    }
}
