import AppKit
import SquirrelCore
import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            PowerSettingsView()
                .tabItem { Label("Power", systemImage: "bolt") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        // A fixed, compact size keeps the window from jumping between tabs;
        // each tab's form scrolls if it ever needs more room.
        .frame(width: 620, height: 540, alignment: .top)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var loginItem: LoginItemService
    @EnvironmentObject private var notifications: NotificationService

    var body: some View {
        Form {
            Section {
                Toggle("Start Squirrel at login", isOn: launchAtLoginBinding)
                if loginItem.requiresApproval {
                    SettingsNote(
                        "macOS is waiting for you to allow this under Login Items in System Settings.",
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
                if let error = loginItem.lastError {
                    SettingsNote(error, symbol: "xmark.circle.fill", tint: .red)
                }
            } footer: {
                SettingsFootnote("Squirrel publishes the UPS for as long as it is running, so macOS only sees your UPS while Squirrel is open.")
            }

        }
        .formStyle(.grouped)
        .task {
            loginItem.refresh()
            await notifications.refreshAuthorizationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Picks up a change the user made in System Settings while this
            // window was open.
            loginItem.refresh()
            Task { await notifications.refreshAuthorizationStatus() }
        }
    }

    /// The system is the source of truth, so the switch reflects what macOS
    /// actually has rather than what Squirrel would like it to have.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )
    }


}

private struct NotificationSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var notifications: NotificationService
    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: notificationsBinding)
                Group {
                    Toggle("Mains power lost or restored", isOn: $settings.preferences.notifyPowerChanges)
                    Toggle("Low battery", isOn: $settings.preferences.notifyLowBattery)
                    Toggle("UPS or NUT server unavailable", isOn: $settings.preferences.notifyConnectionProblems)
                }
                .disabled(!settings.preferences.showNotifications)
                LabeledContent("Permission", value: notifications.statusDescription)
                if settings.preferences.showNotifications, notifications.authorizationStatus == .notDetermined {
                    SettingsNote("Notification setup is incomplete. Allow notifications to receive UPS alerts.", symbol: "exclamationmark.circle", tint: .orange)
                    Button("Allow Notifications…") {
                        Task { await notifications.requestAuthorizationIfNeeded() }
                    }
                }
                if notifications.isDenied {
                    Button("Open Notification Settings") { NotificationService.openNotificationSettings() }
                }
            } header: {
                Text("Notifications")
            } footer: {
                SettingsFootnote("One notification per change, never per reading. A brief network hiccup is not reported; a connection problem must last at least 15 seconds. macOS's notification settings still apply.")
            }
        }.formStyle(.grouped)
        .task { await notifications.refreshAuthorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifications.refreshAuthorizationStatus() }
        }
    }
    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.showNotifications },
            set: { isOn in
                settings.preferences.showNotifications = isOn
                // Ask macOS now, while the reason is on screen, rather than
                // leaving the switch on with nothing behind it.
                if isOn { Task { await notifications.requestAuthorizationIfNeeded() } }
            }
        )
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
            Section {
                Picker("Menu bar", selection: $settings.preferences.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
            } footer: {
                SettingsFootnote("Squirrel's icon always shows the UPS's state. This chooses whether the battery percentage sits beside it.")
            }
        }.formStyle(.grouped)
    }
}

// MARK: - Power

private struct PowerSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: UPSMonitor

    var body: some View {
        Form {
            NativePowerSettings(service: appModel.powerSchedule)
            Section {
                Toggle("Share the UPS with macOS", isOn: $settings.preferences.publishPowerSource)
                LabeledContent("Status") {
                    Label(integration.text, systemImage: integration.symbol)
                        .foregroundStyle(integration.tint)
                        .labelStyle(.titleAndIcon)
                }
                Button("Open Energy Settings") { MenuBarMenu.openEnergySettings() }
                if monitor.systemIntegrationUnavailable {
                    SettingsNote(
                        "This version of macOS is not accepting a UPS from Squirrel, so it cannot handle the shutdown itself.",
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
            } header: {
                Text("macOS Connection")
            } footer: {
                SettingsFootnote("Your UPS appears in System Settings → Energy, where macOS performs the shutdown itself. Turning this off leaves Squirrel as a monitor only.")
            }

            Section {
                Toggle("Keep the Mac awake", isOn: $settings.preferences.preventSleepDuringOutage)
                Picker("Confirm an outage after", selection: $settings.preferences.onBatteryDebounce) {
                    ForEach(Self.debounceChoices, id: \.self) { seconds in
                        Text(Self.secondsLabel(seconds)).tag(seconds)
                    }
                }
                SettingsFootnote("Wait this long before treating a loss of mains power as an outage. Low battery and shutdown signals take effect immediately.")
                Picker("Reading expires after", selection: $settings.preferences.readingMaxAge) {
                    ForEach(Self.maxAgeChoices, id: \.self) { seconds in
                        Text(Self.secondsLabel(seconds)).tag(seconds)
                    }
                }
                SettingsFootnote("If no fresh reading arrives in this time, Squirrel tells macOS the UPS is unavailable.")
            } header: {
                Text("During an Outage")
            } footer: {
                SettingsFootnote("Keep the Mac awake prevents idle sleep during a confirmed outage so macOS can reach its shutdown rules. The display can still sleep, and you can still put the Mac to sleep manually.")
            }
        }
        .formStyle(.grouped)
        .onAppear { appModel.refreshSystemPowerSource(); appModel.refreshPowerProfileAdvice() }
        .onChange(of: settings.preferences.publishPowerSource) { _ in monitor.restart() }
    }

    private static let debounceChoices: [TimeInterval] = [0, 5, 10, 20, 30, 60]
    private static let maxAgeChoices: [TimeInterval] = [15, 30, 60, 120]

    private static func secondsLabel(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "Immediately" }
        guard seconds < 60 else { return "\(Int(seconds) / 60) min" }
        return "\(Int(seconds)) sec"
    }

    private var integration: (text: String, symbol: String, tint: Color) {
        switch appModel.nativeIntegrationState {
        case .published:
            return ("macOS is receiving this UPS", "checkmark.circle.fill", .green)
        case .monitoringOnly:
            return ("Monitoring only", "exclamationmark.circle.fill", .orange)
        case .disconnected:
            return ("Waiting for the UPS", "clock", .secondary)
        case .connecting:
            return ("Starting up", "clock", .secondary)
        case .noUPSConfigured:
            return ("No UPS configured", "minus.circle", .secondary)
        }
    }
}

// MARK: - Shared bits

/// The explanatory line under a settings group.
private struct SettingsFootnote: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A quiet in-form note. Not a banner: one line, one symbol, system colours.
private struct SettingsNote: View {
    private let text: String
    private let symbol: String
    private let tint: Color

    init(_ text: String, symbol: String, tint: Color) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NativePowerSettings: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var service: PowerScheduleService
    @State private var showingSchedule = false
    var body: some View {
        Section("Mac Power") {
            Toggle("Restart after power failure", isOn: Binding(
                get: { appModel.powerProfileAdvice.autoRestartEnabled ?? false },
                set: { value in Task { await service.setAutoRestart(value); appModel.refreshPowerProfileAdvice() } }
            ))
            .disabled(appModel.powerProfileAdvice.autoRestartSupported != true || appModel.powerProfileAdvice.autoRestartEnabled == nil || service.isApplying)
            if appModel.powerProfileAdvice.autoRestartSupported != true {
                Text("This Mac does not report support for automatic restart.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Recovery requires the right hardware and an actual power interruption. A normal shutdown while the UPS stays powered does not guarantee automatic restart.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Power Schedule…") { showingSchedule = true }
            if let error = service.lastError { Text(error).foregroundStyle(.orange) }
        }
        .sheet(isPresented: $showingSchedule) { PowerScheduleView(service: service) }
    }
}
