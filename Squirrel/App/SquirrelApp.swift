import AppKit
import SwiftUI

@main
@MainActor
struct SquirrelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appModel: AppModel

    init() {
        let isRunningTests = NSClassFromString("XCTestCase") != nil
        let model = AppModel(isRunningTests: isRunningTests)
        _appModel = StateObject(wrappedValue: model)
        if !isRunningTests { model.start() }
        appDelegate.appModel = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.monitor)
        } label: {
            MenuBarLabel()
                .environmentObject(appModel)
                .environmentObject(appModel.monitor)
                .environmentObject(appModel.settings)
        }
        // A native NSMenu, not a custom popover. Nothing to animate means
        // nothing to animate incorrectly.
        .menuBarExtraStyle(.menu)

        Window("Set Up Your UPS", id: AppModel.assistantWindowID) {
            ConnectionAssistantWindow()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.monitor)
                .onAppear { appModel.setWindow(.assistant, visible: true) }
                .onDisappear { appModel.setWindow(.assistant, visible: false) }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Squirrel", id: AppModel.manageWindowID) {
            UPSManagementView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.monitor)
                .environmentObject(appModel.history)
                .frame(minHeight: 400)
                .onAppear { appModel.setWindow(.manage, visible: true) }
                .onDisappear { appModel.setWindow(.manage, visible: false) }
        }
        .defaultSize(width: 682, height: 903)
        .windowToolbarStyle(.unified)
        .commands { SquirrelCommands(appModel: appModel) }

        SwiftUI.Settings {
            PreferencesView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.monitor)
                .environmentObject(appModel.loginItem)
                .environmentObject(appModel.notifications)
                .onAppear { appModel.setWindow(.settings, visible: true) }
                .onDisappear { appModel.setWindow(.settings, visible: false) }
        }
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var monitor: UPSMonitor
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            .onAppear(perform: beginSetupOnFirstRun)
            .onReceive(appModel.$shouldOpenManageWindow) { shouldOpen in
                guard shouldOpen else { return }
                openWindow(id: AppModel.manageWindowID)
                NSApp.activate(ignoringOtherApps: true)
                appModel.shouldOpenManageWindow = false
            }
            .onReceive(appModel.$shouldOpenAssistantWindow) { shouldOpen in
                guard shouldOpen else { return }
                openWindow(id: AppModel.assistantWindowID)
                NSApp.activate(ignoringOtherApps: true)
                appModel.shouldOpenAssistantWindow = false
            }
    }

    @ViewBuilder
    private var label: some View {
        let state = appModel.primaryDevice.map { monitor.state(for: $0) } ?? .idle
        let symbol = MenuBarPresentation.symbolName(for: state)
        let text = MenuBarPresentation.menuBarText(for: state, display: settings.preferences.menuBarDisplay)

        // Label renders as icon + title in the menu bar; dropping the title
        // keeps it to a bare glyph when there is nothing worth saying. The two
        // label styles are different types, so this cannot be a ternary.
        if let text {
            Label(text, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Squirrel")
                .accessibilityValue(MenuBarPresentation.summary(for: state))
        } else {
            Label("Squirrel", systemImage: symbol)
                .labelStyle(.iconOnly)
                .accessibilityValue(MenuBarPresentation.summary(for: state))
        }
    }

    /// First run opens the assistant, not the management window. An existing
    /// user has a configured UPS and is never sent through setup again.
    private func beginSetupOnFirstRun() {
        guard settings.devices.isEmpty, appModel.assistant == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard settings.devices.isEmpty, appModel.assistant == nil else { return }
            appModel.beginConnectionAssistant()
        }
    }
}

/// Menu commands for the main window. Adding a UPS is a "new document" in all
/// but name, so it takes File ▸ New's place and shortcut.
private struct SquirrelCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: appModel.updater)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add UPS…") { appModel.beginConnectionAssistant() }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show Power History") { appModel.showHistory() }
                .keyboardShortcut("y")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appModel: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A terminated Squirrel is a vanished UPS: the power source dies with
        // the process that published it. Paired with NSSupportsAutomaticTermination
        // in Info.plist, because a stale copy in /Applications carries the old plist.
        ProcessInfo.processInfo.disableAutomaticTermination("Squirrel publishes the Mac's UPS power source")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appModel?.triggerOpenManageWindow()
        return true
    }
}

/// Hosts the connection assistant in its own window, so the assistant has a
/// window sized for it and the management window keeps its own shape.
private struct ConnectionAssistantWindow: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let assistant = appModel.assistant {
                ConnectionAssistantView(assistant: assistant, onFinish: finish)
                    .navigationTitle(assistant.isEditing ? "Change UPS" : "Set Up Your UPS")
            } else {
                // Reopened from the Window menu with nothing to configure.
                Color.clear
                    .frame(width: 560, height: 460)
                    .onAppear { close() }
            }
        }
    }

    private func finish(with device: UPSDevice?) {
        let configured = device != nil
        appModel.endConnectionAssistant()
        close()
        if configured {
            openWindow(id: AppModel.manageWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// `dismiss` closes a `Window` scene, but the assistant must not be left
    /// on screen if it ever does not, so the window is also closed by hand.
    private func close() {
        dismiss()
        NSApp.windows
            .first { $0.identifier?.rawValue.contains(AppModel.assistantWindowID) == true }?
            .close()
    }
}
