import SquirrelCore
import SwiftUI

/// What Squirrel can establish about whether this Mac is protected by a UPS.
///
/// Three facts are kept apart because they fail separately: macOS seeing the
/// UPS, macOS having shutdown rules to act on, and macOS having been seen to
/// act during a real outage. Recognition and configured rules are reported
/// separately: the shutdown itself is macOS's to perform, and
/// whether it has been seen working is reported separately, never assumed.
struct MacProtectionStatus: Equatable {
    enum Level: Equatable {
        case active
        case attention
        case inactive
        case checking
    }

    var level: Level
    var title: String
    var explanation: String?

    var tint: Color {
        switch level {
        case .active: return .green
        case .attention: return .orange
        case .inactive, .checking: return .secondary
        }
    }

    @MainActor
    static func evaluate(
        device: UPSDevice,
        integration: AppModel.NativeIntegrationState,
        advice: PowerProfileAdvisor.Advice,
        preferences: AppPreferences,
        integrationUnavailable: Bool
    ) -> MacProtectionStatus {
        guard preferences.publishPowerSource else {
            return .init(level: .inactive, title: "Off", explanation: "Presenting the UPS to macOS is turned off in Squirrel's settings, so macOS will not shut this Mac down during an outage.")
        }
        guard device.publishesToSystem else {
            return .init(level: .inactive, title: "Monitoring Only", explanation: "Another UPS protects this Mac. Squirrel is monitoring this one without presenting it to macOS.")
        }
        guard !integrationUnavailable else {
            return .init(level: .attention, title: "Unavailable", explanation: "This version of macOS is not accepting a UPS from Squirrel, so it cannot shut the Mac down during an outage.")
        }

        switch integration {
        case .noUPSConfigured, .connecting:
            return .init(level: .checking, title: "Checking…", explanation: nil)
        case .disconnected:
            return .init(level: .attention, title: "Not Protected", explanation: "Squirrel can't read the UPS, so macOS has been told it isn't present rather than being given a stale reading.")
        case .monitoringOnly:
            return .init(level: .attention, title: "Not Detected", explanation: "Squirrel is reading the UPS, but macOS is not reporting it as a power source yet.")
        case .published:
            guard advice.didReadThresholds else {
                return .init(level: .attention, title: "Rules Unknown", explanation: "macOS sees the UPS, but Squirrel could not read its shutdown settings.")
            }
            guard advice.hasShutdownThreshold else {
                return .init(level: .attention, title: "No Shutdown Rule", explanation: "macOS sees the UPS, but no shutdown rule is set, so the Mac will run until the UPS is exhausted.")
            }
            if advice.needsAttention(whenKeepingAwake: preferences.preventSleepDuringOutage) {
                return .init(level: .attention, title: "Needs Attention", explanation: "Your Mac sleeps \(advice.sleepMinutes ?? 0) min into an outage, so it may never reach its shutdown rule. Turn on “Keep the Mac awake” in Squirrel's settings, or lengthen the UPS sleep timer.")
            }
            return .init(level: .active, title: "Recognised by macOS", explanation: nil)
        }
    }
}

/// A coloured dot and a word. The one status vocabulary used everywhere.
struct StatusBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Mac Protection section reports macOS's rules alongside Squirrel's
/// keep-awake preference. Shutdown rules remain owned by macOS.
struct MacProtectionSection: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: UPSMonitor

    let device: UPSDevice

    private var advice: PowerProfileAdvisor.Advice { appModel.powerProfileAdvice }

    private var status: MacProtectionStatus {
        MacProtectionStatus.evaluate(
            device: device,
            integration: appModel.nativeIntegrationState(for: device),
            advice: advice,
            preferences: settings.preferences,
            integrationUnavailable: monitor.systemIntegrationUnavailable
        )
    }

    var body: some View {
        Section {
            if appModel.protects(device) {
                protectionRows
            }
            if let explanation = status.explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !appModel.protects(device), settings.preferences.publishPowerSource, settings.devices.count > 1 {
                Button("Use This UPS to Protect the Mac") { appModel.useForMacProtection(device) }
            }
        } header: {
            HStack(spacing: 8) {
                Text("Mac Protection")
                Spacer()
                StatusBadge(title: status.title, tint: status.tint)
                    .font(.callout.weight(.regular))
                    .textCase(nil)
                    .accessibilityLabel("Mac Protection")
                    .accessibilityValue(status.title)
            }
        } footer: {
            HStack(alignment: .top) {
                if appModel.protects(device), settings.preferences.preventSleepDuringOutage {
                    Text("Squirrel prevents idle sleep during confirmed outages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if showsSettingsButton {
                    Button("UPS Settings…") { MenuBarView.openEnergySettings() }
                        .buttonStyle(.link)
                        .help("Open UPS Options in System Settings")
                }
            }
        }
    }

    /// macOS owns the sleep and shutdown rules; the one way to change them is
    /// System Settings, offered wherever they apply.
    private var showsSettingsButton: Bool {
        appModel.protects(device) || !settings.preferences.publishPowerSource
    }

    @ViewBuilder
    private var protectionRows: some View {
        LabeledContent("Sleep on UPS power", value: sleepDescription)

        if advice.didReadThresholds {
            if let level = advice.haltLevelPercent {
                LabeledContent("Shut down at", value: "\(level)% battery")
            }
            if let minutes = advice.haltRemainMinutes {
                LabeledContent("Shut down with", value: "\(minutes) min remaining")
            }
            if let minutes = advice.haltAfterMinutes {
                LabeledContent("Shut down after", value: "\(minutes) min on UPS")
            }
            if !advice.hasShutdownThreshold {
                LabeledContent("Automatic shutdown", value: "Not set")
            }
        } else {
            LabeledContent("Automatic shutdown", value: "Unavailable")
        }

        if advice.autoRestartSupported != false {
            LabeledContent("Restart after power failure", value: restartDescription)
        }
    }

    private var restartDescription: String {
        guard advice.autoRestartSupported == true, let enabled = advice.autoRestartEnabled else {
            return "Unavailable"
        }
        return enabled ? "On" : "Off"
    }

    private var sleepDescription: String {
        guard let minutes = advice.sleepMinutes else { return "Unknown" }
        guard minutes > 0 else { return "Never" }
        return "After \(minutes) min"
    }
}
