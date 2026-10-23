import SwiftUI

struct PowerScheduleView: View {
    @ObservedObject var service: PowerScheduleService
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [RepeatingPowerSchedule] = []
    @State private var loaded = false
    @State private var originalBaseline = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Power Schedule").font(.title3.bold())
            Text("macOS manages these schedules, including while Squirrel is closed.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach($draft) { $rule in
                        ScheduleRuleEditor(rule: $rule) { draft.removeAll { $0.id == rule.id } }
                    }
                    Menu {
                        if !draft.contains(where: { $0.action.isOn }) {
                            Button("Start or Wake") { draft.append(.init(action: .wakeorpoweron, minutes: 420, days: 31)) }
                        }
                        if !draft.contains(where: { !$0.action.isOn }) {
                            Button("Sleep, Restart or Shut Down") { draft.append(.init(action: .shutdown, minutes: 1380, days: 127)) }
                        }
                    } label: { Label("Add Schedule", systemImage: "plus") }
                    .disabled(draft.count >= 2 || service.readError != nil)

                    Label("macOS supports one recurring startup/wake rule and one recurring sleep, restart or shutdown rule. These are shared with other apps. Editing them replaces the system's recurring rules; one-time events are preserved.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Startup support depends on your Mac and firmware; acceptance by macOS does not prove the Mac can start from shut down. Use Wake for sleep-only operation. A closed laptop lid, FileVault and power availability can prevent unattended recovery. Sleep, restart and shutdown may be cancelled or blocked by login state or unsaved documents.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = service.readError { errorText(error) }
                    if let error = service.lastError { errorText(error) }
                    if !service.scheduledEvents.isEmpty {
                        Divider()
                        Text("One-Time System Events").font(.headline)
                        Text("Read from macOS. Managed by their original apps; Squirrel leaves them unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(service.scheduledEvents) { event in
                            LabeledContent(event.title) {
                                VStack(alignment: .trailing) {
                                    Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                    Text(event.owner).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Apply may require administrator authentication.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(service.isApplying ? "Applying…" : "Apply") {
                    Task {
                        let previous = service.schedules
                        if await service.apply(draft, expectedBaseline: originalBaseline) {
                            if previous != service.schedules, let device = appModel.settings.systemDevice {
                                appModel.history.record(.scheduleChanged, for: device.id,
                                    detail: "macOS recurring schedule updated. Execution has not been verified.")
                            }
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!loaded || service.isApplying || service.readError != nil || draft == service.schedules || draft.contains { $0.days == 0 })
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .interactiveDismissDisabled(service.isApplying)
        .onAppear { service.refresh(); draft = service.schedules; originalBaseline = service.baseline; loaded = true }
    }

    private func errorText(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
    }
}

private struct ScheduleRuleEditor: View {
    @Binding var rule: RepeatingPowerSchedule
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: rule.action.symbol).foregroundStyle(rule.action.isOn ? .orange : .accentColor)
                Picker("Action", selection: $rule.action) {
                    ForEach(RepeatingPowerSchedule.Action.allCases.filter { $0.isOn == rule.action.isOn }, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }.labelsHidden().frame(width: 150)
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
                Spacer()
                Toggle("Enabled", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel("Enable \(rule.action.title) schedule")
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove schedule")
            }
            HStack(spacing: 4) {
                ForEach(0..<7) { index in
                    Toggle(RepeatingPowerSchedule.dayNames[index], isOn: Binding(
                        get: { rule.days & (1 << index) != 0 },
                        set: { enabled in
                            if enabled { rule.days |= 1 << index } else { rule.days &= ~(1 << index) }
                        }
                    )).toggleStyle(.button)
                }
            }.disabled(!rule.enabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: rule.minutes / 60, minute: rule.minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            rule.minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

struct PowerManagementSection: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var service: PowerScheduleService
    @State private var showingSchedule = false

    var body: some View {
        Section("Power Management") {
            LabeledContent("Restart after power failure", value: restartDescription)
            LabeledContent("Scheduled startup/wake", value: summary(isOn: true))
            LabeledContent("Scheduled sleep/restart/shutdown", value: summary(isOn: false))
            HStack {
                Spacer()
                Button("Edit Schedule…") { showingSchedule = true }
            }
        }
        .sheet(isPresented: $showingSchedule) { PowerScheduleView(service: service) }
        .onAppear { service.refresh() }
    }

    private func summary(isOn: Bool) -> String {
        guard service.readError == nil else { return "Unavailable" }
        guard let rule = service.schedules.first(where: { $0.action.isOn == isOn }) else { return "Not scheduled" }
        return rule.action.title + " · " + rule.summary
    }
    private var restartDescription: String {
        let advice = appModel.powerProfileAdvice
        guard advice.autoRestartSupported == true, let enabled = advice.autoRestartEnabled else { return "Unavailable" }
        return enabled ? "On" : "Off"
    }
}
