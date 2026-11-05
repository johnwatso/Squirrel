import AppKit
import SwiftUI

struct PowerScheduleView: View {
    @ObservedObject var service: PowerScheduleService
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ScheduleEditorSession?
    @State private var showingHelp = false
    @State private var ruleToDelete: RepeatingPowerSchedule?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Power Schedule").font(SquirrelFont.sheetTitle)
                    Text("Automatically manage when your Mac starts, sleeps or shuts down.")
                        .font(SquirrelFont.intro).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3).frame(maxWidth: 450, alignment: .leading)
                }
                Spacer(minLength: 0)
                HelpButton { showingHelp = true }
                    .help("About power schedules")
                    .accessibilityLabel("About power schedules")
                    .popover(isPresented: $showingHelp, arrowEdge: .bottom) { ScheduleHelpView(service: service) }
            }
            .padding(.horizontal, 10)

            VStack(spacing: 12) {
                if service.schedules.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        Text("No Schedules Yet").font(SquirrelFont.sectionTitle)
                        Text("Give your Mac a daily routine.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 26)
                } else {
                    ForEach(service.schedules.sorted { $0.id > $1.id }) { rule in
                        ScheduleCard(rule: rule, enabled: Binding(
                            get: { rule.enabled },
                            set: { enabled in
                                var draft = service.schedules
                                guard let index = draft.firstIndex(where: { $0.id == rule.id }) else { return }
                                draft[index].enabled = enabled
                                apply(draft)
                            }
                        ), edit: { openEditor(rule) }, delete: { ruleToDelete = rule })
                    }
                }

                Button { openEditor(nil) } label: {
                    Label("Add Schedule…", systemImage: "plus")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .disabled(service.schedules.count >= 2)
                .help(service.schedules.count >= 2 ? "Both macOS recurring slots are in use. Edit an existing schedule to change its action." : "Add a power schedule")
                if service.schedules.count >= 2 {
                    Text("Both recurring slots are in use. Edit a schedule to change its action.")
                        .font(SquirrelFont.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(service.isApplying || service.readError != nil)

            if let error = service.readError ?? service.lastError {
                ScheduleErrorMessage(message: error)
            }

            // The two-slot limit is explained once, behind the help button,
            // and noted above only when both slots are in use.

            HStack {
                if service.isApplying {
                    ProgressView().controlSize(.small)
                    Text("Updating schedule…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button { service.clearError(); service.refresh() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r", modifiers: .command)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .disabled(service.isApplying)
        }
        .padding(30)
        .frame(width: 650)
        .interactiveDismissDisabled(service.isApplying)
        // After the sheet is on screen, not during its first layout.
        .task { service.clearError(); service.refresh() }
        // Deleting changes the Mac's own power schedule, so it is confirmed.
        .confirmationDialog(
            "Delete the \(ruleToDelete?.action.cardTitle ?? "") schedule?",
            isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }),
            presenting: ruleToDelete
        ) { rule in
            Button("Delete Schedule", role: .destructive) {
                apply(service.schedules.filter { $0.id != rule.id })
                ruleToDelete = nil
            }
            Button("Cancel", role: .cancel) { ruleToDelete = nil }
        } message: { rule in
            Text(rule.enabled
                 ? "macOS will stop running it. The other schedule is kept."
                 : "It will be removed from Squirrel. The other schedule is kept.")
        }
        .sheet(item: $editor) { session in
            ScheduleEditorSheet(service: service, session: session) { previous in
                recordChange(from: previous)
            }
        }
    }

    private func openEditor(_ rule: RepeatingPowerSchedule?) {
        service.clearError()
        editor = ScheduleEditorSession(rule: rule, schedules: service.schedules, baseline: service.baseline)
    }

    private func apply(_ draft: [RepeatingPowerSchedule]) {
        let baseline = service.baseline
        let previous = service.schedules
        Task {
            if await service.apply(draft, expectedBaseline: baseline) { recordChange(from: previous) }
        }
    }

    private func recordChange(from previous: [RepeatingPowerSchedule]) {
        if previous != service.schedules, let device = appModel.settings.systemDevice {
            let systemChanged = previous.filter(\.enabled).sorted { $0.id < $1.id } != service.schedules.filter(\.enabled).sorted { $0.id < $1.id }
            appModel.history.record(.scheduleChanged, for: device.id,
                detail: systemChanged ? "macOS recurring schedule updated. Execution has not been verified."
                    : "Disabled power schedule updated in Squirrel. No system schedule changed.")
        }
    }
}

/// Freeze the complete pair and its baseline for the lifetime of an edit.
/// Activation refreshes must never make a stale draft safe to write.
struct ScheduleEditorSession: Identifiable {
    let id = UUID()
    let original: RepeatingPowerSchedule?
    let schedules: [RepeatingPowerSchedule]
    let baseline: String
    let initialRule: RepeatingPowerSchedule

    init(rule: RepeatingPowerSchedule?, schedules: [RepeatingPowerSchedule], baseline: String) {
        original = rule
        self.schedules = schedules
        self.baseline = baseline
        initialRule = rule ?? (schedules.contains { $0.action.isOn }
            ? .init(action: .sleep, minutes: 1380, days: 127)
            : .init(action: .wakeorpoweron, minutes: 420, days: 31))
    }

    func allows(_ action: RepeatingPowerSchedule.Action) -> Bool {
        !schedules.contains { $0.id != original?.id && $0.action.isOn == action.isOn }
    }

    func replacing(with rule: RepeatingPowerSchedule) -> [RepeatingPowerSchedule] {
        schedules.filter { $0.id != original?.id } + [rule]
    }
}

private struct ScheduleCard: View {
    let rule: RepeatingPowerSchedule
    @Binding var enabled: Bool
    var edit: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: rule.action.symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(rule.action.scheduleColor)
                .frame(width: 52, height: 52)
                .background(rule.action.scheduleColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.action.cardTitle).font(SquirrelFont.sectionTitle)
                Text(rule.action.detailTitle).font(SquirrelFont.body).foregroundStyle(.secondary)
            }
            .frame(width: 155, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.timeText).font(SquirrelFont.sectionTitle).monospacedDigit()
                Text(rule.recurrenceText).font(SquirrelFont.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Enabled", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel("Enable \(rule.action.cardTitle) schedule")
                .help(rule.enabled ? "Disable this schedule" : "Enable this schedule")
            Menu {
                Button("Edit Schedule…", action: edit)
                Button("Delete Schedule…", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Options for \(rule.action.cardTitle) schedule")
        }
        .padding(14)
        .scheduleSurface()
        .accessibilityElement(children: .contain)
    }
}

struct ScheduleEditorSheet: View {
    @ObservedObject var service: PowerScheduleService
    let session: ScheduleEditorSession
    var didSave: ([RepeatingPowerSchedule]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rule: RepeatingPowerSchedule
    @State private var repeatPreset: ScheduleRepeatPreset
    @State private var showingHelp = false
    private let actions: [RepeatingPowerSchedule.Action] = [.wakeorpoweron, .sleep, .shutdown, .restart]

    init(service: PowerScheduleService, session: ScheduleEditorSession,
         didSave: @escaping ([RepeatingPowerSchedule]) -> Void) {
        self.service = service
        self.session = session
        self.didSave = didSave
        _rule = State(initialValue: session.initialRule)
        _repeatPreset = State(initialValue: ScheduleRepeatPreset(days: session.initialRule.days))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(session.original == nil ? "Add Schedule" : "Edit Schedule")
                .font(SquirrelFont.sheetTitle)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 16)
            Divider()

            ScheduleSheetScroll {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Action")
                        HStack(spacing: 12) {
                            ForEach(actions, id: \.self) { action in
                                actionTile(action)
                            }
                        }
                        if rule.action.isOn {
                            Picker("Wake behaviour", selection: $rule.action) {
                                Text("Start up or wake").tag(RepeatingPowerSchedule.Action.wakeorpoweron)
                                Text("Wake from sleep only").tag(RepeatingPowerSchedule.Action.wake)
                                Text("Start up only").tag(RepeatingPowerSchedule.Action.poweron)
                            }
                            .font(SquirrelFont.caption)
                        }
                        if session.schedules.contains(where: { $0.id != session.original?.id }) {
                            Text("An existing schedule uses the other recurring slot. Edit it to change that action.")
                                .font(SquirrelFont.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Time")
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.stepperField).controlSize(.large)
                            .accessibilityLabel("Scheduled time").frame(width: 140)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Repeat")
                        Picker("Repeat schedule", selection: Binding(get: { repeatPreset }, set: { selectPreset($0) })) {
                            ForEach(ScheduleRepeatPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if repeatPreset == .custom {
                            HStack(spacing: 6) {
                                ForEach(0..<7) { index in
                                    Toggle(RepeatingPowerSchedule.dayNames[index], isOn: day(index))
                                        .toggleStyle(.button).frame(maxWidth: .infinity)
                                        .accessibilityLabel(Self.fullDayNames[index])
                                }
                            }
                            if rule.days == 0 {
                                Text("Select at least one day.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionTitle("Enabled")
                            Text(rule.enabled ? "Schedule is active and will run at the selected time." : "Saved in Squirrel. Enable it when you’re ready.")
                                .font(SquirrelFont.body).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Toggle("Enabled", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel("Schedule enabled")
                    }
                }
                .padding(30)
                .disabled(service.isApplying)

                VStack(alignment: .leading, spacing: 14) {
                    if service.isApplying {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Updating schedule…").foregroundStyle(.secondary)
                        }
                    }
                    if let error = service.lastError ?? service.readError {
                        ScheduleErrorMessage(message: error)
                    }
                    ScheduleInformation(title: "These are macOS power schedules.",
                        detail: "Administrator approval may be required. Existing schedules are shared with other apps.",
                        learnMore: { showingHelp = true })
                        .popover(isPresented: $showingHelp, arrowEdge: .top) { ScheduleHelpView(service: service) }
                }
                .padding(.horizontal, 30).padding(.bottom, 28)
            }

            // Buttons at the bottom trailing edge, Cancel before the default
            // button, as in every macOS sheet.
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { service.clearError(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(session.original == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.days == 0 || !session.allows(rule.action) || service.readError != nil)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .disabled(service.isApplying)
        }
        .frame(width: 580)
        .interactiveDismissDisabled(service.isApplying)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(SquirrelFont.sectionTitle)
    }

    private func actionTile(_ action: RepeatingPowerSchedule.Action) -> some View {
        let selected = action.isOn ? rule.action.isOn : rule.action == action
        // The Wake tile stands for whichever start/wake action the rule uses,
        // so it describes that one, in the same words as the schedule list.
        let described = action.isOn && rule.action.isOn ? rule.action : action
        return Button {
            // Selecting the Wake tile again must preserve wake-only/startup-only.
            if !action.isOn || !rule.action.isOn { rule.action = action }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: action.symbol).font(.system(size: 29, weight: .medium))
                    .foregroundStyle(action.scheduleColor).frame(height: 33)
                Text(action.cardTitle).font(SquirrelFont.bodyEmphasised)
                Text(described.detailTitle)
                    .font(SquirrelFont.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 110)
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.055) : Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selected ? 1.3 : 1) }
        .disabled(!session.allows(action))
        .opacity(session.allows(action) ? 1 : 0.45)
        .accessibilityLabel("\(action.cardTitle), \(described.detailTitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(session.allows(action) ? action.title : "This recurring slot is already in use")
    }

    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: rule.minutes / 60, minute: rule.minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            rule.minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    private func selectPreset(_ preset: ScheduleRepeatPreset) {
        repeatPreset = preset
        if let days = preset.days { rule.days = days }
    }

    private static let fullDayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private func day(_ index: Int) -> Binding<Bool> {
        Binding(get: { rule.days & (1 << index) != 0 }, set: { selected in
            if selected { rule.days |= 1 << index } else { rule.days &= ~(1 << index) }
        })
    }

    private func save() {
        Task {
            if await service.apply(session.replacing(with: rule), expectedBaseline: session.baseline) {
                didSave(session.schedules)
                dismiss()
            }
        }
    }
}

enum ScheduleRepeatPreset: String, CaseIterable, Identifiable {
    case everyDay = "Every Day", weekdays = "Weekdays", weekends = "Weekends", custom = "Custom"
    var id: Self { self }
    var days: Int? {
        switch self {
        case .everyDay: return 127
        case .weekdays: return 31
        case .weekends: return 96
        case .custom: return nil
        }
    }
    init(days: Int) {
        self = Self.allCases.first { $0.days == days } ?? .custom
    }
}

/// Fit the sheet to its contents, scrolling only when custom days or errors
/// would otherwise push controls off a smaller display.
private struct ScheduleSheetScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            VStack(spacing: 0) { content }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ScheduleContentHeight.self, value: geometry.size.height)
                    }
                }
        }
        .frame(height: min(contentHeight, max(360, (NSScreen.main?.visibleFrame.height ?? 900) - 180)))
        .onPreferenceChange(ScheduleContentHeight.self) { contentHeight = $0 }
    }
}

private struct ScheduleContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ScheduleInformation: View {
    let title: String
    let detail: String
    var learnMore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: "info.circle").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Learn more…", action: learnMore).buttonStyle(.link)
            }
            .font(SquirrelFont.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)) }
    }
}

private struct ScheduleErrorMessage: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}

/// Shown in a popover from the help button, never as a sheet on a sheet.
private struct ScheduleHelpView: View {
    @ObservedObject var service: PowerScheduleService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About Power Schedules").font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    helpSection("Two shared recurring slots", "macOS supports one startup or wake rule, plus one sleep, restart or shutdown rule. Multiple rules of the same kind cannot coexist, even on different days. Schedules created in Terminal or another app appear here too.")
                    helpSection("Your other schedules are preserved", "Editing, disabling or deleting a rule updates the recurring pair while keeping the other rule. Squirrel checks for changes made by other apps before applying yours. One-time system events are left unchanged.")
                    helpSection("Disabled schedules stay in Squirrel", "Disabling an active rule removes it from macOS and may require approval. A disabled rule is saved locally and does not run. If another app fills its slot, the active system rule takes precedence.")
                    helpSection("Administrator approval", "macOS requires administrator privileges to change power schedules. Squirrel requests approval only when the active system rules change, and submits the pair together. macOS handles your credentials; Squirrel never sees or stores your password.")
                    helpSection("Wake and startup", "Wake can start your Mac or wake it from sleep, depending on its selected behaviour. These options share one recurring slot. Startup support depends on your Mac and firmware. A closed laptop lid or unavailable power can prevent wake or startup; FileVault requires a login after startup.")
                    helpSection("Before you rely on a schedule", "Your Mac must be awake and you must be logged in for a scheduled shutdown. Unsaved documents can prevent sleep or shutdown. Saving a schedule confirms its settings, not that it has executed. Schedules continue while Squirrel is closed.")
                    Link("Apple’s guide to power schedules", destination: URL(string: "https://support.apple.com/guide/mac-help/mchl40376151/mac")!)
                    if !service.scheduledEvents.isEmpty {
                        Divider()
                        Text("One-Time System Events").font(.headline)
                        Text("Managed by macOS and their original apps.").foregroundStyle(.secondary)
                        ForEach(service.scheduledEvents) { event in
                            HStack(alignment: .top) {
                                Text(event.title)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                    Text(event.owner).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(20).frame(width: 440, height: 480)
    }

    private func helpSection(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension RepeatingPowerSchedule.Action {
    var cardTitle: String { isOn ? "Wake" : title }
    /// What the action does, under its title on cards and tiles. Never the
    /// title again.
    var detailTitle: String {
        switch self {
        case .wake: return "Wake from sleep"
        case .wakeorpoweron: return "Start up or wake"
        case .poweron: return "Start up"
        case .sleep: return "Put the Mac to sleep"
        case .restart: return "Restart the Mac"
        case .shutdown: return "Turn the Mac off"
        }
    }
    var scheduleColor: Color {
        switch self {
        case .wake, .wakeorpoweron, .poweron: return .orange
        case .sleep: return .indigo
        case .shutdown: return .red
        case .restart: return .secondary
        }
    }
}

/// The standard round help button, which SwiftUI only offers from macOS 14.
private struct HelpButton: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.press))
        button.bezelStyle = .helpButton
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press() { action() }
    }
}

private extension View {
    func scheduleSurface() -> some View {
        background(Color(nsColor: .controlBackgroundColor).opacity(0.40), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)) }
    }
}
