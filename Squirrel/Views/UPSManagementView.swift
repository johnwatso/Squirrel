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
    @State private var showingUPSSelector = false
    @State private var dashboardWidth: CGFloat = 682
    @State private var showingDevices = false
    @State private var selectedDeviceID: UPSDevice.ID?
    @State private var deviceToRemove: UPSDevice?
    @State private var deviceToRename: UPSDevice?
    @State private var proposedName = ""

    var body: some View {
        Group {
            if settings.devices.isEmpty {
                noUPSState
            } else {
                dashboard
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { dashboardWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { dashboardWidth = $0 }
            }
        }
        .accessibilityHidden(showingUPSSelector)
        .overlay {
            if showingUPSSelector {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { showingUPSSelector = false }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showingUPSSelector {
                upsSelector
                    .background {
                        Button("Dismiss UPS selector") { showingUPSSelector = false }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)) }
                    .overlay(alignment: .topLeading) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 8))
                            path.addLine(to: CGPoint(x: 8, y: 0))
                            path.addLine(to: CGPoint(x: 16, y: 8))
                        }
                        .fill(.regularMaterial)
                        .frame(width: 16, height: 8)
                        .offset(x: 48, y: -7)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 10)
                    .padding(.trailing, 18)
                    .padding(.top, 1)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Connected UPS")
            }
        }
        .onExitCommand { showingUPSSelector = false }
        .sheet(isPresented: $showingSchedule) { PowerScheduleView(service: appModel.powerSchedule) }
        .sheet(isPresented: $showingDevices) {
            UPSDevicesSheet()
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

    private var dashboard: some View {
        Group {
            if let device = selectedDevice {
                UPSDetailView(device: device).id(device.id)
            }
        }
        .frame(minWidth: 460)
        .navigationTitle("Squirrel")
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { dashboardToolbar.accessibilityElement(children: .contain).accessibilityLabel("Dashboard controls") }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { dashboardToolbar.accessibilityElement(children: .contain).accessibilityLabel("Dashboard controls") }
            }
        }
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 0) {
            Button { showingUPSSelector.toggle() } label: {
                HStack(spacing: 10) {
                    Circle().fill(selectedDevice.map { UPSAppearance.tint(for: monitor.state(for: $0)) } ?? .secondary)
                        .frame(width: 10, height: 10)
                    Text(selectedDevice?.displayName ?? "UPS").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(width: dashboardWidth < 540 ? 140 : 158, height: 35)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Choose a dashboard UPS; this does not change which UPS is shared with macOS")
            Spacer().frame(width: dashboardWidth < 640 ? 8 : 54)
            HStack(spacing: dashboardWidth < 540 ? 6 : 16) {
                Button { showingSchedule = true } label: {
                    Image(systemName: "clock").frame(width: 36, height: 35)
                }
                .help("Power Schedule")
                .accessibilityLabel("Power Schedule")
                Button { appModel.showHistory(for: selectedDevice) } label: {
                    Image(systemName: "chart.xyaxis.line").frame(width: 36, height: 35)
                }
                .help("Power History")
                .accessibilityLabel("Power History")
                Menu {
                    Button("Refresh") {
                        monitor.restart()
                        appModel.refreshPowerProfileAdvice()
                        appModel.powerSchedule.refresh()
                    }
                    if let device = selectedDevice { deviceActions(for: device) }
                    Divider()
                    Button("Manage UPS…") { showingDevices = true }
                    Button("Settings…") { MenuBarMenu.openSettings() }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 36, height: 35)
                .accessibilityLabel("Actions")
            }
            .font(.system(size: 18))
            .buttonStyle(.plain)
        }
    }

    private var upsSelector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connected UPS")
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)
            ForEach(settings.devices) { device in
                Button {
                    selectedDeviceID = device.id
                    showingUPSSelector = false
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                            .opacity(device.id == selectedDeviceID ? 1 : 0)
                            .frame(width: 18)
                        Circle().fill(UPSAppearance.tint(for: monitor.state(for: device)))
                            .frame(width: 10, height: 10).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.displayName).foregroundStyle(.primary)
                            Text(device.publishesToSystem ? (settings.preferences.publishPowerSource ? "Shared with macOS" : "Sharing off") : "Monitoring only")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            DashboardDivider().padding(.vertical, 8)
            Button {
                showingUPSSelector = false
                showingDevices = true
            } label: { Label("Manage UPS…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
            DashboardDivider().padding(.vertical, 8)
            Button {
                showingUPSSelector = false
                appModel.beginConnectionAssistant()
            } label: { Label("Add UPS…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
        }
        .font(.system(size: 14))
        .padding(16)
        .frame(width: 262)
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
        Button("Change Connection…") { appModel.beginConnectionAssistant(editing: device) }
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
