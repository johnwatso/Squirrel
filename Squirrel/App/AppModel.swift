import AppKit
import Foundation
import SquirrelCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let manageWindowID = "manage-ups"
    static let assistantWindowID = "connect-ups"
    static let connectionWindowID = "ups-connection"
    static let historyWindowID = "power-history"

    /// Squirrel's windows. The Dock icon follows whether any of them is on
    /// screen, so the app is a menu bar item when it is only monitoring and a
    /// normal app when you are actually using it.
    enum WindowKind: Hashable {
        case manage
        case assistant
        case connection
        case history
        case settings
    }

    let settings: SettingsStore
    let monitor: UPSMonitor
    let sleepAssertion: SleepAssertionService
    let powerSchedule = PowerScheduleService()
    let publisher: PowerSourcePublisher
    let discovery = NUTDiscoveryService()
    let loginItem = LoginItemService()
    let notifications: NotificationService
    let history: PowerHistory
    let updater = AppUpdater()

    /// The connection assistant, while it is on screen. One at a time, owned
    /// here so the menu bar and the management window open the same one
    /// rather than each growing a configuration screen of its own.
    @Published private(set) var assistant: ConnectionAssistantModel?
    @Published private(set) var connectionEditor: ConnectionEditorModel?

    /// What macOS itself last reported about our UPS. Polled while a window is
    /// open, so the UI shows the system's answer rather than Squirrel's.
    @Published private(set) var systemUPS: SystemPowerSources.Entry?

    @Published var shouldOpenManageWindow = false
    @Published var shouldOpenAssistantWindow = false
    @Published var shouldOpenConnectionWindow = false
    @Published var shouldOpenHistoryWindow = false
    /// Which UPS the history window shows. Set by whoever opens it, so the
    /// menu bar and the main window each open the history they mean.
    @Published var historyDeviceID: UUID?
    @Published private(set) var visibleWindows: Set<WindowKind> = []
    @Published private(set) var powerProfileAdvice = PowerProfileAdvisor.Advice()

    private let advisor = PowerProfileAdvisor()
    private var lastAppliedDockVisibility: Bool?
    private var systemPowerSourceTask: Task<Void, Never>?

    init(isRunningTests: Bool = false) {
        let settings = SettingsStore()
        let publisher = PowerSourcePublisher()
        let sleepAssertion = SleepAssertionService()
        let notifications = NotificationService(settings: settings)
        let history = PowerHistory(inMemory: isRunningTests)
        self.settings = settings
        self.history = history
        self.publisher = publisher
        self.sleepAssertion = sleepAssertion
        self.notifications = notifications
        self.monitor = UPSMonitor(
            settings: settings,
            publisher: publisher,
            sleepAssertion: sleepAssertion,
            notifications: notifications,
            history: history
        )
    }

    func start() {
        updater.start()
        loginItem.refresh()
        Task { await notifications.refreshAuthorizationStatus() }
        monitor.start()
        refreshPowerProfileAdvice()
        powerSchedule.refresh()
        observeSystemPowerEvents()
        SquirrelIntentBridge.configure(with: self)
        CommandService.start()
        // macOS's own settings can change while Squirrel is open; reading
        // them again whenever Squirrel comes forward keeps the window honest.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPowerProfileAdvice()
                self?.refreshSystemPowerSource()
                self?.powerSchedule.refresh()
            }
        }
    }

    func refreshPowerProfileAdvice() {
        powerProfileAdvice = advisor.currentAdvice()
    }

    func triggerOpenManageWindow() {
        shouldOpenManageWindow = true
    }

    func showHistory(for device: UPSDevice? = nil) {
        historyDeviceID = device?.id ?? historyDeviceID ?? primaryDevice?.id
        shouldOpenHistoryWindow = true
    }

    private func observeSystemPowerEvents() {
        for (name, kind) in [(NSWorkspace.didWakeNotification, PowerEventKind.systemWake),
                             (NSWorkspace.willSleepNotification, .systemSleep),
                             (NSWorkspace.willPowerOffNotification, .systemShutdown)] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let device = self.settings.systemDevice else { return }
                    self.history.record(kind, for: device.id, detail: "Reported by macOS. The cause and completion are not verified.")
                }
            }
        }
    }

    // MARK: - Devices

    /// A friendly name is also the name macOS shows in System Settings, so a
    /// rename restarts polling to publish it under the new one straight away.
    func rename(_ device: UPSDevice, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != device.displayName else { return }
        var renamed = device
        renamed.displayName = trimmed
        settings.upsert(renamed)
        monitor.restart()
        refreshSystemPowerSource()
    }

    /// Pins the dashboard picture for a UPS Squirrel recognised wrongly, or
    /// returns it to automatic with nil.
    func setIllustration(_ kind: UPSIllustrationKind?, for device: UPSDevice) {
        guard var updated = settings.device(id: device.id) else { return }
        updated.illustrationOverride = kind?.rawValue
        settings.upsert(updated)
    }

    /// The Mac has one set of UPS shutdown rules, so only one UPS can be the
    /// one it depends on.
    func useForMacProtection(_ device: UPSDevice) {
        settings.setProtectionDevice(device.id)
        monitor.restart()
        refreshSystemPowerSource()
    }

    func remove(_ device: UPSDevice) {
        monitor.forget(device)
        settings.remove(id: device.id)
        monitor.restart()
        refreshSystemPowerSource()
    }

    // MARK: - Dock icon

    func setWindow(_ kind: WindowKind, visible: Bool) {
        if visible {
            visibleWindows.insert(kind)
        } else {
            visibleWindows.remove(kind)
        }
        refreshDockIconVisibility(activateIfShowing: visible)
        updateSystemPowerSourcePolling()
    }

    /// Reading IOKit costs little, but there is no reason to do it when no
    /// window is on screen to show the answer.
    private func updateSystemPowerSourcePolling() {
        if visibleWindows.isEmpty {
            systemPowerSourceTask?.cancel()
            systemPowerSourceTask = nil
            return
        }
        guard systemPowerSourceTask == nil else { return }
        systemPowerSourceTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshSystemPowerSource()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func refreshSystemPowerSource() {
        let name = primaryDevice?.displayName
        systemUPS = SystemPowerSources.current().first { entry in
            guard entry.isUPS else { return false }
            guard let name else { return true }
            return entry.name == name || entry.isNetworkTransport
        }
    }

    /// Shows the Dock icon while any window is on screen and hides it again
    /// when the last one closes.
    ///
    /// Only the policy switch is worth guarding. Activation is a separate
    /// concern: when the policy is already `.regular`, guarding both together
    /// means opening a second window never brings Squirrel forward.
    func refreshDockIconVisibility(activateIfShowing: Bool = false) {
        let shouldShowDockIcon = !visibleWindows.isEmpty
        let policyChanged = lastAppliedDockVisibility != shouldShowDockIcon
        lastAppliedDockVisibility = shouldShowDockIcon
        let shouldActivate = shouldShowDockIcon && activateIfShowing

        guard policyChanged || shouldActivate else { return }

        Task { @MainActor in
            if policyChanged {
                NSApp.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
            }
            if shouldActivate {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - Connection assistant

    /// Onboarding is reserved for adding a UPS.
    func beginConnectionAssistant() {
        assistant = ConnectionAssistantModel(
            settings: settings,
            monitor: monitor,
            publisher: publisher,
            discovery: discovery
        )
        shouldOpenAssistantWindow = true
    }

    func editConnection(_ device: UPSDevice) {
        connectionEditor?.cancel()
        connectionEditor = ConnectionEditorModel(device: settings.device(id: device.id) ?? device, settings: settings, onSave: { [weak self] in
            self?.monitor.restart()
            self?.refreshSystemPowerSource()
        })
        shouldOpenConnectionWindow = true
    }

    func endEditingConnection() {
        connectionEditor?.cancel()
        connectionEditor = nil
    }

    /// Credential repairs use the existing-device editor, not onboarding.
    func beginSigningIn(_ device: UPSDevice) {
        editConnection(device)
        connectionEditor?.showsAuthentication = true
    }

    /// Runs a UPS command from the menu bar or the window, which only offer
    /// them for a UPS with a saved sign-in. A refusal is explained on its own rather than
    /// shown as the UPS having failed.
    func runCommand(_ command: String, titled title: String, on device: UPSDevice) async {
        guard MenuBarPresentation.canRunCommands(on: device) else { return }
        do {
            try await monitor.runInstantCommand(command, on: device)
        } catch {
            let refusal = MenuBarPresentation.commandRefusal(error, commandTitle: title, username: device.username)
            if askToSignIn(title: refusal.title, message: refusal.message, signInTitle: refusal.offersSignIn ? "Change Sign-In…" : nil) {
                beginSigningIn(device)
            }
        }
    }

    /// A modal alert, brought to the front because it is usually raised from
    /// the menu bar. True when the user chose to sign in.
    private func askToSignIn(title: String, message: String, signInTitle: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let signInTitle {
            alert.addButton(withTitle: signInTitle)
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn && signInTitle != nil
    }

    func endConnectionAssistant() {
        discovery.stop()
        assistant = nil
        refreshSystemPowerSource()
        refreshPowerProfileAdvice()
    }

    // MARK: - Status

    /// What macOS itself currently reports, which is the honest answer to
    /// "is the integration actually working?".
    var systemUPSDescription: String {
        guard let ups = SystemPowerSources.current().first(where: { $0.isUPS }) else {
            return "macOS does not currently see a UPS."
        }
        let capacity = ups.currentCapacity.map { "\($0)%" } ?? "unknown"
        return "macOS sees \(ups.name) at \(capacity) (\(ups.state ?? "unknown"))."
    }

    /// Connected to the server, reading real telemetry, and accepted by
    /// macOS are three different things, and the UI must not blur them.
    enum NativeIntegrationState: Equatable {
        case noUPSConfigured
        case connecting
        /// The NUT server cannot be reached, or refused us.
        case disconnected(String)
        /// Reading the UPS, but macOS is not reporting it as a power source.
        case monitoringOnly
        /// macOS is reporting the UPS Squirrel published.
        case published(SystemPowerSources.Entry)
    }

    var nativeIntegrationState: NativeIntegrationState {
        guard let device = primaryDevice else { return .noUPSConfigured }
        return nativeIntegrationState(for: device)
    }

    func nativeIntegrationState(for device: UPSDevice) -> NativeIntegrationState {
        switch monitor.state(for: device) {
        case .idle, .connecting:
            return .connecting
        case .failed(let message):
            return .disconnected(message)
        case .online:
            guard device.publishesToSystem, settings.preferences.publishPowerSource else { return .monitoringOnly }
            guard let entry = systemUPS, entry.isPresent, entry.name == device.displayName else {
                return .monitoringOnly
            }
            return .published(entry)
        }
    }

    /// Whether this UPS is the one the Mac's protection depends on: the one
    /// presented to macOS, with presenting switched on.
    func protects(_ device: UPSDevice) -> Bool {
        device.publishesToSystem && settings.preferences.publishPowerSource
    }

    /// The device whose reading drives the menu bar icon.
    var primaryDevice: UPSDevice? {
        settings.systemDevice ?? settings.devices.first
    }
}
