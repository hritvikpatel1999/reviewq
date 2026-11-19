import ReviewQCore
import SwiftUI

struct ReminderSettings: View {
    @Binding var configuration: ReminderConfiguration
    @ObservedObject var reminders: ReminderStore
    let saveHint: String
    let openSystemSettings: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable review reminders", isOn: $configuration.isEnabled)
                    .accessibilityIdentifier("reminders-enabled")
                    .disabled(reminders.isWorking)
                Text("Off by default. Generic local reminders, even when your queue is empty. Click one to open your queue.")
                    .font(.caption).foregroundStyle(.secondary)
                if configuration.isEnabled {
                    schedule
                        .disabled(reminders.isWorking)
                    permission
                    Text(saveHint).font(.caption).foregroundStyle(.secondary)
                    if configuration == reminders.configuration, reminders.isScheduled {
                        Label("Your saved schedule is active.", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let validationError {
                    Text(validationError).font(.caption).foregroundStyle(.red)
                }
                if let error = reminders.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Label("Review reminders", systemImage: "bell.badge") }
        .onChange(of: configuration.isEnabled) { wasEnabled, isEnabled in
            if isEnabled && !wasEnabled { reminders.requestPermission() }
        }
        .onAppear { reminders.requestSynchronization() }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Days").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                    Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: Binding(
                        get: { configuration.weekdays.contains(day) },
                        set: { selected in
                            if selected { configuration.weekdays.insert(day) }
                            else { configuration.weekdays.remove(day) }
                        }
                    ))
                    .toggleStyle(.button).controlSize(.small)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                }
            }
            ForEach(configuration.times.indices, id: \.self) { index in
                HStack {
                    ReminderTimePicker(title: "Time \(index + 1)", time: $configuration.times[index])
                    Button {
                        configuration.times.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove reminder \(index + 1)")
                    .help("Remove this reminder time")
                }
            }
            HStack {
                Button("Add time", systemImage: "plus", action: addTime)
                    .disabled(configuration.times.count >= ReminderConfiguration.maximumTimes)
                Spacer()
                Text("\(configuration.times.count) \(configuration.times.count == 1 ? "reminder" : "reminders") per selected day")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Up to 8 per selected day. Uses this Mac's local time zone. macOS controls delivery during Focus and sleep.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Play a sound", isOn: $configuration.playsSound)
                .accessibilityIdentifier("reminders-sound")
        }
    }

    @ViewBuilder
    private var permission: some View {
        if reminders.isWorking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking reminders...").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            switch reminders.authorization {
            case .notDetermined:
                Button("Allow notifications") { reminders.requestPermission() }
            case .denied:
                Text("Notifications are blocked by macOS. You can still finish setup or save your settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Notifications settings", action: openSystemSettings)
            case .unavailable:
                Text("Run the built ReviewQ app to use notifications.").font(.caption).foregroundStyle(.secondary)
            case .authorized:
                HStack {
                    Button("Send test notification") { reminders.sendTest(playsSound: configuration.playsSound) }
                    if reminders.errorMessage != nil, reminders.configuration.isEnabled {
                        Button("Retry saved schedule") { reminders.requestSynchronization(force: true) }
                    }
                }
                if reminders.testRequested {
                    Text("Test requested. Check Notification Center if no banner appears.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var validationError: String? {
        do { try configuration.validate(); return nil }
        catch { return error.localizedDescription }
    }

    private func addTime() {
        let occupied = Set(configuration.times.map(\.minuteOfDay))
        var minute = ((configuration.times.last?.minuteOfDay ?? 570) + 60) % 1_440
        while occupied.contains(minute) { minute = (minute + 30) % 1_440 }
        configuration.times.append(ReminderTime(hour: minute / 60, minute: minute % 60))
    }
}

private struct ReminderTimePicker: View {
    let title: String
    @Binding var time: ReminderTime

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { Date(timeIntervalSince1970: TimeInterval(time.minuteOfDay * 60)) },
            set: { date in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .gmt
                time = ReminderTime(hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date))
            }
        ), displayedComponents: .hourAndMinute)
        // The picker edits a wall-clock value, not an instant that can shift during DST.
        .environment(\.timeZone, .gmt)
        .frame(maxWidth: 240, alignment: .leading)
    }
}
