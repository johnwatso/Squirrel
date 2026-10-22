import AppKit
import SquirrelCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: UPSMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group { menuContents }
            .onAppear {
                appModel.refreshSystemPowerSource()
                appModel.refreshPowerProfileAdvice()
            }
    }

    @ViewBuilder
    private var menuContents: some View {
        if settings.devices.isEmpty {
            Text("No UPS configured")
            Button("Set Up a UPS…") { appModel.beginConnectionAssistant() }
        } else {
            ForEach(settings.devices) { device in
                if settings.devices.count == 1 {
                    deviceSummary(device)
                } else {
                    Menu(device.displayName) {
                        deviceSummary(device)
                        Divider()
                        Button("Show Power History…") { appModel.showHistory(for: device) }
                    }
                }
            }
            protectionSummary
        }

        warningSection

        Divider()

        Button("Open Squirrel") { openMainWindow() }
            .keyboardShortcut("o")
        if !settings.devices.isEmpty {
            Button("Show Power History") { appModel.showHistory() }
                .keyboardShortcut("y")
        }
        Button("Open UPS Settings…") { Self.openEnergySettings() }

        if !settings.devices.isEmpty {
            controlsMenu
        }

        Divider()

        Button("Settings…") { Self.openSettings() }
            .keyboardShortcut(",")
        CheckForUpdatesButton(updater: appModel.updater)
        Button("Quit Squirrel") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: - Sections

    /// A concise native menu summary using this device's current reading.
    @ViewBuilder
    private func deviceSummary(_ device: UPSDevice) -> some View {
        let state = monitor.state(for: device)
        Text(device.displayName)
            .fontWeight(.semibold)
        Label(UPSAppearance.shortStatus(for: state), systemImage: "circle.fill")
            .foregroundStyle(UPSAppearance.tint(for: state))
        ForEach(MenuBarPresentation.measurementLines(for: state), id: \.self) { line in
            Text(line)
        }
        if case .failed(let message) = state {
            Text(message)
        }
    }

    /// Whether the Mac is protected, in the same words as the window.
    @ViewBuilder
    private var protectionSummary: some View {
        if let device = settings.systemDevice, appModel.protects(device) {
            let status = MacProtectionStatus.evaluate(
                device: device,
                integration: appModel.nativeIntegrationState(for: device),
                advice: appModel.powerProfileAdvice,
                preferences: settings.preferences,
                integrationUnavailable: monitor.systemIntegrationUnavailable
            )
            Text("Mac Protection: \(status.title)")
        }
    }

    @ViewBuilder
    private var warningSection: some View {
        if monitor.systemIntegrationUnavailable {
            Divider()
            Text("macOS is not accepting a UPS from Squirrel")
        }
    }

    /// Occasional actions, kept out of the top level of the menu.
    private var controlsMenu: some View {
        Menu("Controls") {
            Button("Refresh Now") {
                monitor.restart()
                appModel.refreshPowerProfileAdvice()
            }
            if monitor.isPaused {
                Button("Resume Monitoring") { monitor.resume() }
            } else {
                Button("Pause Monitoring") { Task { await monitor.pause() } }
            }
            ForEach(settings.devices) { device in
                commandItems(for: device)
            }
            Divider()
            Button("Add UPS…") { appModel.beginConnectionAssistant() }
        }
    }

    @ViewBuilder
    private func commandItems(for device: UPSDevice) -> some View {
        let supported = monitor.commands(for: device)
        let offered = MenuBarPresentation.offeredCommands.filter { supported.contains($0.command) }

        if !offered.isEmpty {
            Divider()
            if settings.devices.count > 1 {
                Text(device.displayName)
            }
            ForEach(offered, id: \.command) { item in
                Button(item.title) {
                    Task { await monitor.runInstantCommand(item.command, on: device) }
                }
                .disabled(monitor.isBusy(device))
            }
        }
    }

    // MARK: - Actions

    private func openMainWindow() {
        openWindow(id: AppModel.manageWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// SettingsLink is macOS 14+. Squirrel targets Ventura, so open the
    /// Settings scene through the responder chain, whose selector was renamed
    /// in macOS 14.
    static func openSettings() {
        let selector: Selector = if #available(macOS 14, *) {
            Selector(("showSettingsWindow:"))
        } else {
            Selector(("showPreferencesWindow:"))
        }
        NSApp.sendAction(selector, to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func openEnergySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Energy-Saver-Settings") else { return }
        NSWorkspace.shared.open(url)
    }
}
