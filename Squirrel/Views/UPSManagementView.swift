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
        if settings.devices.count > 1, !device.publishesToSystem {
            Button("Share with macOS") { appModel.useForMacProtection(device) }
        }
        Button("Show Power History") { appModel.showHistory(for: device) }
        Divider()
        Button("Remove UPS…", role: .destructive) { deviceToRemove = device }
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
