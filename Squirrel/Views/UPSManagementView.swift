import AppKit
import SquirrelCore
import SwiftUI

/// Dashboard selection is local to this window. Mac protection is configured
/// separately and never changes when a different dashboard is selected.
struct UPSManagementView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: UPSMonitor

    @State private var showingSchedule = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedDeviceID: UPSDevice.ID?
    @State private var deviceToRemove: UPSDevice?
    @State private var deviceToRename: UPSDevice?
    @State private var proposedName = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            if settings.devices.isEmpty {
                noUPSState
                    .frame(minWidth: 460)
                    .navigationTitle("Squirrel")
            } else {
                dashboard
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingSchedule) { PowerScheduleView(service: appModel.powerSchedule) }
        // Every battery test, from the menu bar or this window, is confirmed here.
        .sheet(item: $appModel.batteryTestRequest) { request in
            if let device = settings.device(id: request.deviceID) {
                BatteryTestSheet(device: device, command: request.command)
            }
        }
        .onAppear(perform: validateSelection)
        .onChange(of: settings.devices) { _ in validateSelection() }
        .confirmationDialog(
            "Remove “\(deviceToRemove?.displayName ?? "this UPS")”?",
            isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }),
            presenting: deviceToRemove
        ) { device in
            Button("Remove UPS", role: .destructive) { remove(device) }
            Button("Cancel", role: .cancel) { deviceToRemove = nil }
        } message: { _ in
            Text("Squirrel will stop monitoring this UPS, macOS will no longer see it as a power source, and its power history will be deleted. A UPS that is simply offline will reconnect on its own.")
        }
        .alert(
            "Rename UPS",
            isPresented: Binding(get: { deviceToRename != nil }, set: { if !$0 { deviceToRename = nil } }),
            presenting: deviceToRename
        ) { device in
            TextField("Name", text: $proposedName)
            Button("Rename") { appModel.rename(device, to: proposedName) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This name is also what macOS shows for the UPS in System Settings.")
        }
    }

    // MARK: - Layout

    private var dashboard: some View {
        Group {
            if let device = selectedDevice {
                UPSDetailView(device: device).id(device.id)
            }
        }
        .frame(minWidth: 460)
        // The window is about the selected UPS, so its title names it.
        .navigationTitle(selectedDevice?.displayName ?? "Squirrel")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // App-wide Settings… lives in the app menu (⌘,), so this menu
                // holds only what acts on the window and its selected UPS.
                Menu {
                    Button("Power Schedule…") { showingSchedule = true }
                    Divider()
                    Button("Refresh") {
                        monitor.restart()
                        appModel.refreshPowerProfileAdvice()
                        appModel.powerSchedule.refresh()
                    }
                    if let device = selectedDevice { deviceActions(for: device) }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("Actions")

                Button { appModel.showHistory(for: selectedDevice) } label: {
                    Label("Power History", systemImage: "clock.arrow.circlepath")
                }
                .help("Power History")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedDeviceID) {
            Section("UPS Devices") {
                ForEach(settings.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.batteryblock.fill")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.displayName)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(UPSAppearance.shortStatus(for: monitor.state(for: device), isPaused: monitor.isPaused))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Circle()
                            .fill(UPSAppearance.tint(for: monitor.state(for: device)))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 4)
                    .tag(device.id)
                    .help(device.displayName)
                    .accessibilityElement(children: .combine)
                    .contextMenu { deviceActions(for: device) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 14) {
                    Button { appModel.beginConnectionAssistant() } label: {
                        Label("Add UPS…", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .help("Add UPS")
                    Button { deviceToRemove = selectedDevice } label: {
                        Label("Remove UPS…", systemImage: "minus")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(selectedDevice == nil)
                    .help("Remove selected UPS")
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func deviceActions(for device: UPSDevice) -> some View {
        Button("Rename…") { beginRename(device) }
        Picker("Picture", selection: Binding(
            get: { device.illustrationOverride.flatMap(UPSIllustrationKind.init(rawValue:)) },
            set: { appModel.setIllustration($0, for: device) }
        )) {
            Text("Automatic").tag(UPSIllustrationKind?.none)
            Divider()
            ForEach(UPSIllustrationKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(UPSIllustrationKind?.some(kind))
            }
        }
        Button("Connection…") { appModel.editConnection(device) }
        commandsMenu(for: device)
        if settings.devices.count > 1, !device.publishesToSystem {
            Button("Share with macOS") { appModel.useForMacProtection(device) }
        }
        Button("Show Power History") { appModel.showHistory(for: device) }
        Divider()
        Button("Remove UPS…", role: .destructive) { deviceToRemove = device }
    }

    /// The same commands as the menu bar's Controls submenu. Without a NUT
    /// sign-in they can't run, so the submenu offers the sign-in instead of
    /// disappearing, as long as the UPS has something worth signing in for.
    @ViewBuilder
    private func commandsMenu(for device: UPSDevice) -> some View {
        let offered = MenuBarPresentation.offeredCommands(
            supported: monitor.commands(for: device),
            reading: monitor.state(for: device).reading,
            signedIn: true
        )
        if !offered.isEmpty {
            let signedIn = MenuBarPresentation.canRunCommands(on: device)
            Menu("UPS Commands") {
                // Battery tests are always offered: their warning asks for a
                // sign-in itself. Other commands need one saved first.
                ForEach(offered.filter { signedIn || MenuBarPresentation.needsBatteryWarning($0.command) }, id: \.command) { item in
                    Button(item.title) {
                        if MenuBarPresentation.needsBatteryWarning(item.command) {
                            appModel.requestBatteryTest(item, on: device)
                        } else {
                            Task { await appModel.runCommand(item.command, titled: item.title, on: device) }
                        }
                    }
                    .disabled(monitor.isBusy(device))
                }
                if !signedIn, offered.contains(where: { !MenuBarPresentation.needsBatteryWarning($0.command) }) {
                    Divider()
                    Button("Sign In to Run Other Commands…") { appModel.beginSigningIn(device) }
                }
            }
        }
    }

    private func beginRename(_ device: UPSDevice) {
        proposedName = device.displayName
        deviceToRename = device
    }

    private var noUPSState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No UPS Connected")
                .font(.title3.weight(.semibold))
            Text("Squirrel makes a network UPS available to macOS, just like a USB-connected one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Add UPS…") { appModel.beginConnectionAssistant() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection

    private var selectedDevice: UPSDevice? {
        selectedDeviceID.flatMap { id in settings.devices.first { $0.id == id } }
    }

    /// Keeps the selection pointing at something that still exists, and
    /// defaults to the UPS macOS is being told about.
    private func validateSelection() {
        if let selectedDeviceID, settings.devices.contains(where: { $0.id == selectedDeviceID }) { return }
        selectedDeviceID = appModel.primaryDevice?.id ?? settings.devices.first?.id
    }

    private func remove(_ device: UPSDevice) {
        appModel.remove(device)
        deviceToRemove = nil
        validateSelection()
    }
}

/// The warning before a battery test or calibration. Running one puts the
/// load on the battery on purpose, and a battery that fails partway through
/// cuts power to this Mac with no clean shutdown, so this says so plainly and
/// leaves Cancel as the safe choice. A UPS without a saved NUT sign-in asks
/// for one here rather than sending people to the connection editor.
struct BatteryTestSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let device: UPSDevice
    let command: MenuBarPresentation.OfferedCommand

    @State private var username = ""
    @State private var password = ""
    @State private var isRunning = false
    @State private var failure: (title: String, message: String)?

    private var isCalibration: Bool { command.command == "calibrate.start" }
    private var needsSignIn: Bool { !MenuBarPresentation.canRunCommands(on: device) }
    private var actionTitle: String { isCalibration ? "Start Calibration" : "Run Self-Test" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isCalibration ? "Calibrate Battery Runtime?" : "Run a Battery Self-Test?")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            Text(isCalibration
                 ? "“\(device.displayName)” will run on its battery until it is nearly empty, to measure how long it really lasts. This can take an hour or more, and the UPS has little in reserve until it recharges."
                 : "“\(device.displayName)” will switch to its battery for a short time to check it, then back to mains power. Your equipment normally stays powered throughout.")
                .fixedSize(horizontal: false, vertical: true)

            warning

            if needsSignIn {
                signIn
            }

            if let failure {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.title).fontWeight(.semibold)
                        Text(failure.message).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()
                if isRunning { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Deliberately not the default button: Return must not start it.
                Button(actionTitle, action: run)
                    .disabled(isRunning || (needsSignIn && username.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(isRunning)
    }

    private var warning: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("If the battery fails, this Mac will shut down abruptly.")
                    .fontWeight(.semibold)
                Text("A worn battery can give out during the test. The UPS would then cut power to this Mac and everything else plugged into it straight away, with no chance to shut down properly. Save your work before you start.")
                if MenuBarPresentation.mayOutlastShutdownRules(command.command) {
                    Text("It can also run long enough for macOS to start its own shutdown under your UPS rules.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your NUT server only runs tests for a user allowed to send it commands.")
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Username").foregroundStyle(.secondary)
                    TextField("Username", text: $username).labelsHidden().autocorrectionDisabled()
                }
                GridRow {
                    Text("Password").foregroundStyle(.secondary)
                    SecureField("Password", text: $password).labelsHidden()
                }
            }
            .textFieldStyle(.roundedBorder)
            Text("Saved to this UPS's connection once the server accepts the test. Passwords are stored in your login Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(isRunning)
    }

    private func run() {
        isRunning = true
        failure = nil
        let typed = needsSignIn ? username.trimmingCharacters(in: .whitespaces) : nil
        Task {
            do {
                try await appModel.runBatteryTest(command.command, on: device, username: typed, password: needsSignIn ? password : nil)
                dismiss()
            } catch {
                let refusal = MenuBarPresentation.commandRefusal(error, commandTitle: actionTitle, username: typed ?? device.username)
                failure = (refusal.title, refusal.message)
            }
            isRunning = false
        }
    }
}

