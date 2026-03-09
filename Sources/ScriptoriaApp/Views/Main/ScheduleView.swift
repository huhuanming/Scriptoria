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

    var isRunning: Bool {
        appState.runningScriptIds.contains(script.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Schedules", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()

                // Run Now button
                Button {
                    Task { await appState.runScript(script) }
                } label: {
                    HStack(spacing: 4) {
                        if isRunning {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Run Now")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentGradient.opacity(isRunning ? 0.3 : 1.0), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .help("Execute script immediately")

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
                        Text("Add a schedule or use Run Now")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(schedules) { schedule in
                        ScheduleRow(schedule: schedule, script: script)
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

/// Single schedule row with edit + run now
struct ScheduleRow: View {
    let schedule: Schedule
    let script: Script
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false
    @State private var showEditSheet = false

    var isRunning: Bool {
        appState.runningScriptIds.contains(script.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Toggle enabled
            Button {
                Task { await appState.toggleSchedule(schedule) }
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
                    NextRunLabel(date: next)
                }
            }

            Spacer()

            if isHovering {
                // Run now
                Button {
                    Task { await appState.runScript(script) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .help("Run now")
                .transition(.scale.combined(with: .opacity))

                // Edit
                Button {
                    showEditSheet = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit schedule")
                .transition(.scale.combined(with: .opacity))

                // Delete
                Button {
                    Task { await appState.removeSchedule(schedule) }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(Theme.failureColor)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                let installed = LaunchdHelper.isInstalled(scheduleId: schedule.id)
                StatusDot(color: installed ? Theme.successColor : .gray, size: 6)
                    .help(installed ? "Active in launchd" : "Not active")
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
        .sheet(isPresented: $showEditSheet) {
            EditScheduleSheet(schedule: schedule, script: script, isPresented: $showEditSheet)
                .environmentObject(appState)
        }
    }
}

/// Sheet for adding a new schedule
struct AddScheduleSheet: View {
    let script: Script
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState

    @State private var mode: ScheduleMode = .daily
    @State private var intervalMinutes: Int = 30
    @State private var dailyHour: Int = 9
    @State private var dailyMinute: Int = 0
    @State private var weeklyHour: Int = 9
    @State private var weeklyMinute: Int = 0
    @State private var selectedDays: Set<Int> = [2, 3, 4, 5, 6]

    var body: some View {
        ScheduleFormContent(
            title: "Add Schedule",
            scriptTitle: script.title,
            mode: $mode,
            intervalMinutes: $intervalMinutes,
            dailyHour: $dailyHour,
            dailyMinute: $dailyMinute,
            weeklyHour: $weeklyHour,
            weeklyMinute: $weeklyMinute,
            selectedDays: $selectedDays,
            actionLabel: "Add Schedule",
            isValid: isValid,
            onCancel: { isPresented = false },
            onAction: {
                await appState.addSchedule(scriptId: script.id, type: scheduleType)
                isPresented = false
            }
        )
    }

    var scheduleType: ScheduleType {
        ScheduleFormContent.buildScheduleType(mode: mode, intervalMinutes: intervalMinutes, dailyHour: dailyHour, dailyMinute: dailyMinute, weeklyHour: weeklyHour, weeklyMinute: weeklyMinute, selectedDays: selectedDays)
    }

    var isValid: Bool {
        ScheduleFormContent.validate(mode: mode, intervalMinutes: intervalMinutes, selectedDays: selectedDays)
    }
}

/// Sheet for editing an existing schedule
struct EditScheduleSheet: View {
    let schedule: Schedule
    let script: Script
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState

    @State private var mode: ScheduleMode
    @State private var intervalMinutes: Int
    @State private var dailyHour: Int
    @State private var dailyMinute: Int
    @State private var weeklyHour: Int
    @State private var weeklyMinute: Int
    @State private var selectedDays: Set<Int>

    init(schedule: Schedule, script: Script, isPresented: Binding<Bool>) {
        self.schedule = schedule
        self.script = script
        self._isPresented = isPresented

        // Parse existing schedule type into form state
        switch schedule.type {
        case .interval(let seconds):
            _mode = State(initialValue: .interval)
            _intervalMinutes = State(initialValue: max(1, Int(seconds / 60)))
            _dailyHour = State(initialValue: 9)
            _dailyMinute = State(initialValue: 0)
            _weeklyHour = State(initialValue: 9)
            _weeklyMinute = State(initialValue: 0)
            _selectedDays = State(initialValue: [2, 3, 4, 5, 6])
        case .daily(let hour, let minute):
            _mode = State(initialValue: .daily)
            _intervalMinutes = State(initialValue: 30)
            _dailyHour = State(initialValue: hour)
            _dailyMinute = State(initialValue: minute)
            _weeklyHour = State(initialValue: hour)
            _weeklyMinute = State(initialValue: minute)
            _selectedDays = State(initialValue: [2, 3, 4, 5, 6])
        case .weekly(let weekdays, let hour, let minute):
            _mode = State(initialValue: .weekly)
            _intervalMinutes = State(initialValue: 30)
            _dailyHour = State(initialValue: hour)
            _dailyMinute = State(initialValue: minute)
            _weeklyHour = State(initialValue: hour)
            _weeklyMinute = State(initialValue: minute)
            _selectedDays = State(initialValue: Set(weekdays))
        case .cron:
            _mode = State(initialValue: .interval)
            _intervalMinutes = State(initialValue: 60)
            _dailyHour = State(initialValue: 9)
            _dailyMinute = State(initialValue: 0)
            _weeklyHour = State(initialValue: 9)
            _weeklyMinute = State(initialValue: 0)
            _selectedDays = State(initialValue: [2, 3, 4, 5, 6])
        }
    }

    var body: some View {
        ScheduleFormContent(
            title: "Edit Schedule",
            scriptTitle: script.title,
            mode: $mode,
            intervalMinutes: $intervalMinutes,
            dailyHour: $dailyHour,
            dailyMinute: $dailyMinute,
            weeklyHour: $weeklyHour,
            weeklyMinute: $weeklyMinute,
            selectedDays: $selectedDays,
            actionLabel: "Save",
            isValid: isValid,
            onCancel: { isPresented = false },
            onAction: {
                await appState.updateSchedule(schedule, newType: scheduleType)
                isPresented = false
            }
        )
    }

    var scheduleType: ScheduleType {
        ScheduleFormContent.buildScheduleType(mode: mode, intervalMinutes: intervalMinutes, dailyHour: dailyHour, dailyMinute: dailyMinute, weeklyHour: weeklyHour, weeklyMinute: weeklyMinute, selectedDays: selectedDays)
    }

    var isValid: Bool {
        ScheduleFormContent.validate(mode: mode, intervalMinutes: intervalMinutes, selectedDays: selectedDays)
    }
}

// MARK: - Shared schedule form

enum ScheduleMode: String, CaseIterable {
    case interval = "Interval"
    case daily = "Daily"
    case weekly = "Weekly"
}

struct ScheduleFormContent: View {
    let title: String
    let scriptTitle: String
    @Binding var mode: ScheduleMode
    @Binding var intervalMinutes: Int
    @Binding var dailyHour: Int
    @Binding var dailyMinute: Int
    @Binding var weeklyHour: Int
    @Binding var weeklyMinute: Int
    @Binding var selectedDays: Set<Int>
    let actionLabel: String
    let isValid: Bool
    let onCancel: () -> Void
    let onAction: () async -> Void

    let dayNames = [(1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat")]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(scriptTitle)
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
                    timePicker(hour: $dailyHour, minute: $dailyMinute)
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .weekly:
                    timePicker(hour: $weeklyHour, minute: $weeklyMinute)
                    daySelector
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 4)

            Divider()

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(actionLabel) {
                    Task { await onAction() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 440, height: 340)
    }

    func timePicker(hour: Binding<Int>, minute: Binding<Int>) -> some View {
        HStack {
            Text("Time")
            Picker("Hour", selection: hour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%02d", h)).tag(h)
                }
            }
            .frame(width: 70)
            Text(":")
            Picker("Minute", selection: minute) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                    Text(String(format: "%02d", m)).tag(m)
                }
            }
            .frame(width: 70)
        }
    }

    var daySelector: some View {
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
    }

    var previewText: String {
        let type = Self.buildScheduleType(mode: mode, intervalMinutes: intervalMinutes, dailyHour: dailyHour, dailyMinute: dailyMinute, weeklyHour: weeklyHour, weeklyMinute: weeklyMinute, selectedDays: selectedDays)
        return type.displayText
    }

    static func buildScheduleType(mode: ScheduleMode, intervalMinutes: Int, dailyHour: Int, dailyMinute: Int, weeklyHour: Int, weeklyMinute: Int, selectedDays: Set<Int>) -> ScheduleType {
        switch mode {
        case .interval:
            return .interval(TimeInterval(intervalMinutes * 60))
        case .daily:
            return .daily(hour: dailyHour, minute: dailyMinute)
        case .weekly:
            return .weekly(weekdays: Array(selectedDays).sorted(), hour: weeklyHour, minute: weeklyMinute)
        }
    }

    static func validate(mode: ScheduleMode, intervalMinutes: Int, selectedDays: Set<Int>) -> Bool {
        switch mode {
        case .interval: return intervalMinutes > 0
        case .daily: return true
        case .weekly: return !selectedDays.isEmpty
        }
    }
}
