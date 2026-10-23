import SwiftUI

struct UPSDevicesView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: UPSMonitor
    @State private var removing: UPSDevice?

    var body: some View {
        Form {
            Section {
                if settings.devices.isEmpty { Text("No UPS configured").foregroundStyle(.secondary) }
                ForEach(settings.devices) { device in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(device.displayName).font(.headline)
                            Spacer()
                            StatusBadge(title: UPSAppearance.shortStatus(for: monitor.state(for: device)), tint: UPSAppearance.tint(for: monitor.state(for: device)))
                        }
                        Text(device.publishesToSystem ? (settings.preferences.publishPowerSource ? "Shared with macOS" : "Sharing off") : "Monitoring only")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Connection…") { appModel.beginConnectionAssistant(editing: device) }
                            if !device.publishesToSystem {
                                Button("Share with macOS") { appModel.useForMacProtection(device) }
                            }
                            Spacer()
                            Button("Remove…", role: .destructive) { removing = device }
                        }
                    }.padding(.vertical, 4)
                }
                Button("Add UPS…") { appModel.beginConnectionAssistant() }
            } footer: {
                Text("One UPS is shared with macOS. Choosing a dashboard doesn't change which one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove UPS and its history?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { device in
            Button("Remove \(device.displayName)", role: .destructive) { appModel.remove(device); removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { device in
            Text(device.publishesToSystem ? "macOS will lose its UPS until you share another one. This UPS's history will be deleted." : "Monitoring will stop and this UPS's history will be deleted.")
        }
    }
}

struct UPSDevicesSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("UPS Devices").font(.title3.bold()).padding(20)
            UPSDevicesView()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
        }.frame(width: 580, height: 440)
    }
}
