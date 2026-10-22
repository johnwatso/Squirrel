import AppKit
import SquirrelCore
import SwiftUI

/// Squirrel's main window: one UPS, in focus, with the sidebar out of the way
/// until there is a reason for it.
struct UPSManagementView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: UPSMonitor

    @State private var selectedDeviceID: UPSDevice.ID?
    @State private var deviceToRemove: UPSDevice?
    @State private var deviceToRename: UPSDevice?
    @State private var proposedName = ""

    var body: some View {
        Group {
            if settings.devices.isEmpty {
                noUPSState
            } else {
                splitView
            }
        }
        .sheet(isPresented: $appModel.isShowingPowerHistory) {
            PowerHistorySheet()
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

    private var splitView: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            Group {
                if let device = selectedDevice {
                    UPSDetailView(device: device)
                        .id(device.id)
                } else {
                    Text("Select a UPS")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Keeps the detail readable when the sidebar opens: the window
            // widens to make room rather than squeezing the values out.
            .navigationSplitViewColumnWidth(min: 400, ideal: 440)
        }
        // Showing the sidebar makes room for it instead of squeezing the
        // values out of the detail; hiding it lets the window come back in.
        .frame(minWidth: isSidebarShown ? 640 : 420)
        // The UPS's name heads the content; the window is Squirrel's.
        .navigationTitle("Squirrel")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    monitor.restart()
                    appModel.refreshPowerProfileAdvice()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the UPS and the Mac's power settings again now")

                Button {
                    appModel.showHistory(for: selectedDevice)
                } label: {
                    Label("Power History", systemImage: "chart.xyaxis.line")
                }
                .help("Show this UPS's power history")

                Menu {
                    if let device = selectedDevice {
                        deviceActions(for: device)
                        Divider()
                    }
                    Button("Add UPS…") { appModel.beginConnectionAssistant() }
                    Divider()
                    Button("Settings…") { MenuBarView.openSettings() }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .help("Rename, reconnect or remove this UPS")
            }
        }
    }

    @ViewBuilder
    private func deviceActions(for device: UPSDevice) -> some View {
        Button("Rename…") { beginRename(device) }
        Button("Change Connection…") { appModel.beginConnectionAssistant(editing: device) }
        if settings.devices.count > 1, !device.publishesToSystem {
            Button("Use to Protect This Mac") { appModel.useForMacProtection(device) }
        }
        Button("Show Power History") { appModel.showHistory(for: device) }
        Divider()
        Button("Remove UPS…", role: .destructive) { deviceToRemove = device }
    }

    private func beginRename(_ device: UPSDevice) {
        proposedName = device.displayName
        deviceToRename = device
    }

    /// Until the user chooses, one UPS gets no sidebar and several get one.
    /// Once they show or hide it, that choice is remembered, and adding a
    /// second UPS is not on its own a reason to override it.
    private var isSidebarShown: Bool {
        settings.preferences.sidebarVisible ?? (settings.devices.count > 1)
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isSidebarShown ? .all : .detailOnly },
            set: { visibility in
                let shown = visibility != .detailOnly
                // Split views write back the value they were given while
                // laying out; only a real change counts as the user's choice.
                guard shown != isSidebarShown else { return }
                settings.preferences.sidebarVisible = shown
            }
        )
    }

    private var sidebar: some View {
        List(selection: $selectedDeviceID) {
            ForEach(settings.devices) { device in
                SidebarRow(device: device, state: monitor.state(for: device))
                    .tag(device.id)
                    .contextMenu { deviceActions(for: device) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                appModel.beginConnectionAssistant()
            } label: {
                Label("Add UPS", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var noUPSState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No UPS connected")
                .font(.title3.weight(.semibold))
            Text("Squirrel makes a network UPS available to macOS, just like a USB-connected one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Connect a UPS…") { appModel.beginConnectionAssistant() }
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

// MARK: - Sidebar row

private struct SidebarRow: View {
    let device: UPSDevice
    let state: UPSConnectionState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: MenuBarPresentation.symbolName(for: state))
                .foregroundStyle(UPSAppearance.tint(for: state))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .lineLimit(1)
                Text(UPSAppearance.shortStatus(for: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
