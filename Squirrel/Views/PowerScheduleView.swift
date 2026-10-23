import SwiftUI

struct PowerScheduleView: View {
    @ObservedObject var service: PowerScheduleService
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ScheduleEditorSession?
    @State private var showingHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Power Schedule").font(.system(size: 28, weight: .bold))
                    Text("Automatically manage when your Mac starts, sleeps or shuts down.")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3).frame(maxWidth: 450, alignment: .leading)
                }
                Spacer(minLength: 0)
                Button { showingHelp = true } label: {
                    Image(systemName: "questionmark").font(.system(size: 16, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain).help("About power schedules")
                .accessibilityLabel("About power schedules")
            }
            .padding(.horizontal, 10)

            VStack(spacing: 12) {
                if service.schedules.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        Text("No schedules yet").font(.system(size: 17, weight: .semibold))
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
                        ), edit: { openEditor(rule) }, delete: {
                            apply(service.schedules.filter { $0.id != rule.id })
                        })
                    }
                }

                Button { openEditor(nil) } label: {
                    Label("Add Schedule", systemImage: "plus.circle")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 62)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .scheduleSurface()
                .padding(.top, 12)
                .disabled(service.schedules.count >= 2)
                .help(service.schedules.count >= 2 ? "Both macOS recurring slots are in use. Edit an existing schedule to change its action." : "Add a power schedule")
                if service.schedules.count >= 2 {
                    Text("Both recurring slots are in use. Edit a schedule to change its action.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(service.isApplying || service.readError != nil)

            if let error = service.readError ?? service.lastError {
                ScheduleErrorMessage(message: error)
            }

            ScheduleInformation(title: "macOS supports two recurring power schedules.",
                detail: "One startup/wake and one sleep, restart or shutdown rule. Changes may require administrator approval.",
                learnMore: { showingHelp = true })

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
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .disabled(service.isApplying)
        }
        .padding(30)
        .frame(width: 650)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        .background(.regularMaterial)
        .interactiveDismissDisabled(service.isApplying)
        .onAppear { service.clearError(); service.refresh() }
        .sheet(item: $editor) { session in
            ScheduleEditorSheet(service: service, session: session) { previous in
                recordChange(from: previous)
            }
        }
        .sheet(isPresented: $showingHelp) { ScheduleHelpSheet(service: service) }
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
                Text(rule.action.cardTitle).font(.system(size: 17, weight: .semibold))
                Text(rule.action.detailTitle).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .frame(width: 155, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.timeText).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                Text(rule.recurrenceText).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Enabled", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel("Enable \(rule.action.cardTitle) schedule")
                .help(rule.enabled ? "Disable this schedule" : "Enable this schedule")
            Menu {
                Button("Edit Schedule…", action: edit)
                Button("Delete Schedule", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(0.045), in: Circle())
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
            HStack {
                Button("Cancel") { service.clearError(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(session.original == nil ? "Add" : "Save", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(rule.days == 0 || !session.allows(rule.action) || service.readError != nil)
            }
            .controlSize(.large)
            .overlay {
                Text(session.original == nil ? "Add Schedule" : "Edit Schedule")
                    .font(.system(size: 17, weight: .semibold)).allowsHitTesting(false)
            }
            .padding(.horizontal, 30).padding(.vertical, 20)
            .disabled(service.isApplying)
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
                            .font(.system(size: 13))
                        }
                        if session.schedules.contains(where: { $0.id != session.original?.id }) {
                            Text("An existing schedule uses the other recurring slot. Edit it to change that action.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
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
                        ScheduleRepeatPicker(selection: presetBinding)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
                        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.06)).allowsHitTesting(false) }
                        .overlay(alignment: .trailing) {
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary).padding(.trailing, 18).allowsHitTesting(false).accessibilityHidden(true)
                        }
                        .accessibilityLabel("Repeat schedule").accessibilityValue(repeatPreset.rawValue)
                        HStack(spacing: 10) {
                            ForEach(ScheduleRepeatPreset.allCases) { preset in
                                Button { selectPreset(preset) } label: {
                                    Text(preset.rawValue).font(.system(size: 14))
                                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(repeatPreset == preset ? Color.accentColor : .primary)
                                .background(repeatPreset == preset ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04), in: Capsule())
                                .overlay { Capsule().strokeBorder(repeatPreset == preset ? Color.accentColor.opacity(0.65) : .clear) }
                                .accessibilityAddTraits(repeatPreset == preset ? .isSelected : [])
                            }
                        }
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
                                .font(.system(size: 14)).foregroundStyle(.secondary)
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
                }
                .padding(.horizontal, 30).padding(.bottom, 28)
            }
        }
        .frame(width: 580)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        .background(.regularMaterial)
        .interactiveDismissDisabled(service.isApplying)
        .sheet(isPresented: $showingHelp) { ScheduleHelpSheet(service: service) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 17, weight: .semibold))
    }

    private func actionTile(_ action: RepeatingPowerSchedule.Action) -> some View {
        let selected = action.isOn ? rule.action.isOn : rule.action == action
        return Button {
            // Selecting the Wake tile again must preserve wake-only/startup-only.
            if !action.isOn || !rule.action.isOn { rule.action = action }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: action.symbol).font(.system(size: 29, weight: .medium))
                    .foregroundStyle(action.scheduleColor).frame(height: 33)
                Text(action.cardTitle).font(.system(size: 14, weight: .semibold))
                Text(action.isOn ? "Start / Wake" : action.title)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 110)
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.055) : Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selected ? 1.3 : 1) }
        .disabled(!session.allows(action))
        .opacity(session.allows(action) ? 1 : 0.45)
        .accessibilityLabel(action.isOn ? "Wake or start up" : action.title)
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

    private var presetBinding: Binding<ScheduleRepeatPreset> {
        Binding(get: { repeatPreset }, set: selectPreset)
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

/// SwiftUI's macOS Menu sizes its click target to the title. A native pop-up
/// button keeps this entire row clickable and retains standard keyboard use.
private struct ScheduleRepeatPicker: NSViewRepresentable {
    @Binding var selection: ScheduleRepeatPreset

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: ScheduleRepeatPreset.allCases.map(\.rawValue))
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.font = .systemFont(ofSize: 15)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("Repeat schedule")
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        button.selectItem(withTitle: selection.rawValue)
        button.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<ScheduleRepeatPreset>
        init(selection: Binding<ScheduleRepeatPreset>) { self.selection = selection }
        @objc func changed(_ sender: NSPopUpButton) {
            guard let title = sender.titleOfSelectedItem, let preset = ScheduleRepeatPreset(rawValue: title) else { return }
            selection.wrappedValue = preset
        }
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
            .font(.system(size: 13))
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

private struct ScheduleHelpSheet: View {
    @ObservedObject var service: PowerScheduleService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("About Power Schedules").font(.title2.bold())
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
                .font(.system(size: 14)).padding(.trailing, 8)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(28).frame(width: 560, height: 600)
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
    var detailTitle: String {
        switch self {
        case .wake: return "Wake from Sleep"
        case .wakeorpoweron: return "Start Up or Wake"
        case .poweron: return "Power On"
        default: return title
        }
    }
    var scheduleColor: Color {
        switch self {
        case .wake, .wakeorpoweron, .poweron: return .yellow
        case .sleep: return Color(red: 0.49, green: 0.28, blue: 0.98)
        case .shutdown: return .red
        case .restart: return .secondary
        }
    }
}

private extension View {
    func scheduleSurface() -> some View {
        background(Color(nsColor: .controlBackgroundColor).opacity(0.40), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)) }
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
