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
        // The menu itself is an AppKit NSMenu (see MenuBarMenu). This
        // never-inserted extra stays first so SwiftUI has a scene that does
        // not open at launch; without it the first Window below would.
        MenuBarExtra("Squirrel", systemImage: "bolt.fill", isInserted: .constant(false)) {
            EmptyView()
        }

        Window("Set Up Squirrel", id: AppModel.assistantWindowID) {
            ConnectionAssistantWindow()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.monitor)
                .onAppear { appModel.setWindow(.assistant, visible: true) }
                .onDisappear {
                    // Closing the window is cancelling: stop the network scan
                    // and drop the half-finished setup.
                    if appModel.assistant != nil { appModel.endConnectionAssistant() }
                    appModel.setWindow(.assistant, visible: false)
                }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Connection", id: AppModel.connectionWindowID) {
            UPSConnectionWindow()
                .environmentObject(appModel)
                .onAppear { appModel.setWindow(.connection, visible: true) }
                .onDisappear {
                    appModel.endEditingConnection()
                    appModel.setWindow(.connection, visible: false)
                }
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
        .defaultSize(width: 682, height: 760)
        .windowToolbarStyle(.unified)
        .commands { SquirrelCommands(appModel: appModel) }

        Window("UPS History", id: AppModel.historyWindowID) {
            PowerHistoryView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .environmentObject(appModel.history)
                .onAppear { appModel.setWindow(.history, visible: true) }
                .onDisappear { appModel.setWindow(.history, visible: false) }
        }
        .defaultSize(width: 680, height: 700)

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

/// Hosted invisibly inside the status item, so SwiftUI's window opening and
/// first-run setup have a view that lives as long as the menu bar item.
struct MenuBarLifecycle: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear(perform: beginSetupOnFirstRun)
            .onReceive(appModel.$shouldOpenManageWindow) { shouldOpen in
                guard shouldOpen else { return }
                openWindow(id: AppModel.manageWindowID)
                NSApp.activate(ignoringOtherApps: true)
                appModel.shouldOpenManageWindow = false
            }
            .onReceive(appModel.$shouldOpenConnectionWindow) { shouldOpen in
                guard shouldOpen else { return }
                openWindow(id: AppModel.connectionWindowID)
                NSApp.activate(ignoringOtherApps: true)
                appModel.shouldOpenConnectionWindow = false
            }
            .onReceive(appModel.$shouldOpenHistoryWindow) { shouldOpen in
                guard shouldOpen else { return }
                openWindow(id: AppModel.historyWindowID)
                NSApp.activate(ignoringOtherApps: true)
                appModel.shouldOpenHistoryWindow = false
            }
            .onReceive(appModel.$shouldOpenAssistantWindow) { shouldOpen in
                guard shouldOpen else { return }
                openWindow(id: AppModel.assistantWindowID)
                NSApp.activate(ignoringOtherApps: true)
                appModel.shouldOpenAssistantWindow = false
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
            Button("Show UPS History") { appModel.showHistory() }
                .keyboardShortcut("y")
        }
    }
}

/// Answers a deferred quit once, whichever of "history written" and "waited
/// long enough" comes first.
@MainActor
private final class QuitReply {
    private let application: NSApplication
    private var sent = false

    init(_ application: NSApplication) { self.application = application }

    func send() {
        guard !sent else { return }
        sent = true
        application.reply(toApplicationShouldTerminate: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appModel: AppModel?
    private var menuBarMenu: MenuBarMenu?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A terminated Squirrel is a vanished UPS: the power source dies with
        // the process that published it. Paired with NSSupportsAutomaticTermination
        // in Info.plist, because a stale copy in /Applications carries the old plist.
        ProcessInfo.processInfo.disableAutomaticTermination("Squirrel publishes the Mac's UPS power source")

        #if DEBUG
        // For screenshots: `-SquirrelAppearance Dark` (or `Light`) forces every
        // window's appearance without changing the system's. Documented in
        // Documentation/UI-Verification.md.
        switch UserDefaults.standard.string(forKey: "SquirrelAppearance") {
        case "Dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "Light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif

        guard let appModel, NSClassFromString("XCTestCase") == nil else { return }
        MainActor.assumeIsolated {
            let lifecycle = NSHostingView(rootView: MenuBarLifecycle()
                .environmentObject(appModel)
                .environmentObject(appModel.settings))
            menuBarMenu = MenuBarMenu(appModel: appModel, lifecycleView: lifecycle)
            #if DEBUG
            menuBarMenu?.openForVerificationIfRequested()
            #endif
        }
    }

    /// Quitting waits, briefly, for the history to be written: the last
    /// minute of readings and the event saying monitoring stopped. A history
    /// that will not finish never holds up the quit for long.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appModel, NSClassFromString("XCTestCase") == nil else { return .terminateNow }
        MainActor.assumeIsolated {
            let quit = QuitReply(sender)
            Task { @MainActor in
                await appModel.prepareToQuit()
                quit.send()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                quit.send()
            }
        }
        return .terminateLater
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
                    .navigationTitle(assistant.windowTitle)
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

/// The editor has its own window and lifecycle, separate from the setup wizard.
private struct UPSConnectionWindow: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let editor = appModel.connectionEditor {
                UPSConnectionView(editor: editor) {
                    dismiss()
                    appModel.endEditingConnection()
                }
                .id(editor.id)
            } else {
                Color.clear.frame(width: 500, height: 200)
                    .onAppear { dismiss() }
            }
        }
    }
}
