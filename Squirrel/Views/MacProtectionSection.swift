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
        /// Sharing with macOS is turned off in Squirrel's settings.
        case notShared
        case inactive
        case checking
    }

    var level: Level
    /// The card's status word: "Connected", "No Shutdown Rule".
    var title: String
    /// The same state as one line for the menu: "Connected to macOS".
    var summary: String
    var explanation: String?
    /// Whether macOS is reporting the UPS as a power source, whatever else
    /// still needs attention.
    var isConnected = false

    var tint: Color {
        switch level {
        case .active: return .green
        case .attention: return .orange
        case .notShared, .inactive, .checking: return .secondary
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
            return .init(level: .notShared, title: "Off", summary: "Not shared with macOS", explanation: "Sharing the UPS with macOS is turned off, so macOS won't shut this Mac down during an outage.")
        }
        guard device.publishesToSystem else {
            return .init(level: .inactive, title: "Monitoring Only", summary: "Monitoring only", explanation: "Another UPS is shared with macOS. Squirrel is monitoring this one without sharing it.")
        }
        guard !integrationUnavailable else {
            return .init(level: .attention, title: "Unavailable", summary: "macOS isn't accepting this UPS", explanation: "This version of macOS is not accepting a UPS from Squirrel, so it cannot shut the Mac down during an outage.")
        }

        switch integration {
        case .noUPSConfigured, .connecting:
            return .init(level: .checking, title: "Checking…", summary: "Checking macOS connection…", explanation: nil)
        case .disconnected:
            return .init(level: .attention, title: "Not Connected", summary: "macOS can't see this UPS", explanation: "Squirrel can't read the UPS, so it has told macOS the UPS isn't present rather than pass on a stale reading.")
        case .monitoringOnly:
            return .init(level: .attention, title: "Not Detected", summary: "macOS can't see this UPS", explanation: "Squirrel is reading the UPS, but macOS is not reporting it as a power source yet.")
        case .published:
            guard advice.didReadThresholds else {
                return .init(level: .attention, title: "Rules Unknown", summary: "Connected · shutdown rules unknown", explanation: "macOS sees the UPS, but Squirrel could not read its shutdown settings.", isConnected: true)
            }
            guard advice.hasShutdownThreshold else {
                return .init(level: .attention, title: "No Shutdown Rule", summary: "Connected · no shutdown rule", explanation: "macOS sees the UPS, but no shutdown rule is set, so the Mac will run until the UPS is exhausted.", isConnected: true)
            }
            if advice.needsAttention(whenKeepingAwake: preferences.preventSleepDuringOutage) {
                return .init(level: .attention, title: "Needs Attention", summary: "Connected · Mac may sleep first", explanation: "Your Mac sleeps \(advice.sleepMinutes ?? 0) min into an outage, so it may never reach its shutdown rule. Turn on “Keep the Mac awake” in Squirrel's settings, or lengthen the UPS sleep timer.", isConnected: true)
            }
            // Green only once macOS sees the UPS and has a rule to act on.
            return .init(level: .active, title: "Connected", summary: "Connected to macOS", explanation: nil, isConnected: true)
        }
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
        VStack(spacing: 13) {
            // A status, not a control: the action it used to hide is the
            // Open Energy Settings button at the foot of the card.
            DashboardSectionHeading(title: "macOS Connection", symbol: "power.circle") {
                HStack(spacing: 10) {
                    Circle().fill(status.tint).frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(status.title).foregroundStyle(DashboardPalette.secondary)
                }
                .help(status.summary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("macOS Connection: \(status.title)")
            }
            if appModel.protects(device) {
                VStack(spacing: 0) {
                    DashboardRow(title: "Sleep on UPS power", value: sleepDescription)
                        .help(settings.preferences.preventSleepDuringOutage ? "Squirrel prevents idle sleep during confirmed outages." : "macOS controls sleep while on UPS power.")
                    if advice.didReadThresholds {
                        if let level = advice.haltLevelPercent {
                            protectionRow("Shut down at", "\(level)% battery")
                        }
                        if let minutes = advice.haltRemainMinutes {
                            protectionRow("Shut down with", "\(minutes) min remaining")
                        }
                        if let minutes = advice.haltAfterMinutes {
                            protectionRow("Shut down after", "\(minutes) min on UPS")
                        }
                        if !advice.hasShutdownThreshold { protectionRow("Automatic shutdown", "Not set") }
                    } else {
                        protectionRow("Automatic shutdown", "Unavailable")
                    }
                }
                .dashboardCard(radius: 10)
            }
            if let explanation = status.explanation {
                Text(explanation)
                    .foregroundStyle(DashboardPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                if showsSettingsButton {
                    Button("Open Energy Settings") { MenuBarMenu.openEnergySettings() }
                }
                if !settings.preferences.publishPowerSource {
                    // The same switch as Settings ▸ "Share the UPS with macOS",
                    // which restarts monitoring so the UPS is published at once.
                    Button("Share with macOS") {
                        settings.preferences.publishPowerSource = true
                        monitor.restart()
                    }
                } else if !appModel.protects(device), settings.devices.count > 1 {
                    Button("Share This UPS with macOS") { appModel.useForMacProtection(device) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .dashboardCard()
    }

    private var showsSettingsButton: Bool {
        appModel.protects(device) || !settings.preferences.publishPowerSource
    }

    @ViewBuilder
    private func protectionRow(_ title: String, _ value: String) -> some View {
        DashboardDivider().padding(.horizontal, 18)
        DashboardRow(title: title, value: value)
    }

    private var sleepDescription: String {
        guard let minutes = advice.sleepMinutes else { return "Unknown" }
        guard minutes > 0 else { return "Never" }
        return "After \(minutes) min"
    }
}
