import AppKit
import SquirrelCore
import SwiftUI

/// Colours and short phrases shared by the window, the sidebar and the
/// menu bar, so one UPS never reads two different ways.
enum UPSAppearance {
    static func tint(for severity: UPSSeverity) -> Color {
        switch severity {
        case .normal: return .green
        case .caution: return .orange
        case .critical: return .red
        }
    }

    static func tint(for state: UPSConnectionState) -> Color {
        switch state {
        case .online(let reading): return tint(for: UPSStatusPresentation.severity(for: reading.status))
        case .failed: return .red
        case .connecting, .idle: return .secondary
        }
    }

    /// "Connected · On mains power" — the connection and the UPS's own state
    /// are two different things and both belong here.
    static func statusLine(for state: UPSConnectionState) -> String {
        switch state {
        case .online(let reading): return "Connected · \(UPSStatusPresentation.headline(for: reading.status))"
        case .connecting: return "Connecting…"
        case .failed: return "Not connected"
        case .idle: return "Not monitoring"
        }
    }

    static func shortStatus(for state: UPSConnectionState) -> String {
        switch state {
        case .online(let reading): return UPSStatusPresentation.headline(for: reading.status)
        case .connecting: return "Connecting…"
        case .failed: return "Not connected"
        case .idle: return "Not monitoring"
        }
    }
}


/// Everything about one UPS, in the order people ask about it: is it working,
/// how long would it last, what is it drawing, and is the Mac protected.
///
/// Explicit card geometry follows the dashboard reference. Expanded details
/// and additional status messages remain scrollable without changing bindings.
struct UPSDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var monitor: UPSMonitor

    let device: UPSDevice

    private var state: UPSConnectionState { monitor.state(for: device) }
    /// The live reading, or the last one Squirrel had when it is not live.
    private var reading: UPSReading? { monitor.lastReading(for: device) }
    private var isLive: Bool { state.reading != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    UPSIdentityHeader(device: device, state: state, reading: reading)
                        .padding(.horizontal, 12)
                        .padding(.top, 20)
                        .padding(.bottom, 14)
                    if let reading {
                        DashboardDivider()
                        UPSMeasurements(reading: reading, isLive: isLive)
                            .padding(.horizontal, 28)
                            .padding(.top, 20)
                            .padding(.bottom, 14)
                    }
                    NameSuggestionRow(device: device, reading: reading)
                        .padding(.horizontal, 20)
                    if let trouble = troubleMessage {
                        Label(trouble.text, systemImage: trouble.symbol)
                            .foregroundStyle(trouble.tint)
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(20)
                    }
                }
                .dashboardCard()
                .padding(.bottom, 9)

                MacProtectionSection(device: device)
                DashboardPowerManagementSection(service: appModel.powerSchedule)
                    .padding(.bottom, 16)
                technicalSection
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 33)
        }
        .background(DashboardPalette.background)
        .font(.system(size: 14))
        .onAppear { appModel.refreshSystemPowerSource() }
    }

    // MARK: - Trouble

    /// The one thing most worth flagging, kept to a single quiet line.
    ///
    /// A UPS fault, a lost connection to the NUT server and a failed macOS
    /// integration are three different problems; integration has its own
    /// section, so this covers the first two.
    private var troubleMessage: (text: String, symbol: String, tint: Color)? {
        if case .failed(let message) = state {
            let suffix = reading == nil ? "" : " The values above are the last ones Squirrel received."
            return (message + suffix, "exclamationmark.triangle.fill", .orange)
        }
        guard let reading = state.reading else { return nil }
        switch UPSStatusPresentation.severity(for: reading.status) {
        case .critical:
            return (UPSStatusPresentation.headline(for: reading.status), "exclamationmark.triangle.fill", .red)
        case .caution where reading.status.contains(.replaceBattery):
            return ("This UPS reports that its battery needs replacing.", "exclamationmark.triangle.fill", .orange)
        case .caution, .normal:
            return nil
        }
    }

    // MARK: - Technical information

    private var technicalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureRow("Technical Information", isExpanded: $settings.preferences.technicalInfoExpanded, labelSpacing: 18) {
                technicalRows
            } trailing: {
                FreshnessLabel(updated: monitor.lastUpdated[device.id], isLive: isLive, maxAge: settings.preferences.readingMaxAge)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .dashboardCard()
    }

    @ViewBuilder
    private var technicalRows: some View {
        if let reading {
            group("Battery", UPSTelemetry.batteryFields(for: reading))
            group("Electrical", UPSTelemetry.electricalFields(for: reading))
            group("Device", UPSTelemetry.deviceFields(for: reading))
        }

        TechnicalHeading("Connection")
        LabeledContent("NUT server", value: "\(device.host):\(String(device.port))")
            .textSelection(.enabled)
        LabeledContent("UPS identifier", value: device.upsName)
            .textSelection(.enabled)
        if let username = device.username, !username.isEmpty {
            LabeledContent("Username", value: username)
        }
        LabeledContent("Status", value: connectionDescription)
        LabeledContent("Last successful update") {
            if let updated = monitor.lastUpdated[device.id] {
                Text(updated.formatted(date: .omitted, time: .standard))
            } else {
                Text("Never")
            }
        }

        if let observed = monitor.protectionVerifiedAt[device.id] {
            LabeledContent("Outage observed", value: observed.formatted(date: .abbreviated, time: .shortened))
        } else if appModel.protects(device) {
            LabeledContent("Outage observed", value: "Not yet")
                .help("Recognition by macOS does not mean an outage or shutdown has been tested.")
        }
        if let reading {
            ForEach(UPSTelemetry.driverFields(for: reading)) { field in
                LabeledContent(field.label, value: field.value)
                    .textSelection(.enabled)
            }
        } else {
            Text("Squirrel has no reading from this UPS yet, so there is nothing more to show.")
                .font(.caption)
                .foregroundStyle(DashboardPalette.secondary)
        }
    }

    private var connectionDescription: String {
        switch state {
        case .online: return "Connected"
        case .connecting: return "Connecting…"
        case .failed: return "Not connected"
        case .idle: return monitor.isPaused ? "Paused" : "Not monitoring"
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ fields: [UPSTelemetryField]) -> some View {
        if !fields.isEmpty {
            TechnicalHeading(title)
            ForEach(fields) { field in
                LabeledContent(field.label, value: field.value)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Overview pieces

/// The friendly name and whether the UPS is working. Make, model and the NUT
/// identifier all live in Technical Information.
private struct UPSIdentityHeader: View {
    @EnvironmentObject private var appModel: AppModel
    let device: UPSDevice
    let state: UPSConnectionState
    let reading: UPSReading?
    @State private var choosingPicture = false

    var body: some View {
        HStack(spacing: 21) {
            Button { choosingPicture = true } label: {
                UPSDeviceIllustration(kind: device.illustration(for: reading))
                    .frame(width: 115, height: 88)
            }
            .buttonStyle(.plain)
            .help("Change Picture")
            .accessibilityLabel("Change Picture")
            .popover(isPresented: $choosingPicture, arrowEdge: .bottom) {
                UPSIllustrationPicker(
                    detected: UPSIllustrationKind(reading: reading),
                    selection: device.illustrationOverride.flatMap(UPSIllustrationKind.init(rawValue:))
                ) { kind in
                    appModel.setIllustration(kind, for: device)
                    choosingPicture = false
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(device.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                if let identity = UPSTelemetry.identity(for: reading) {
                    Text(identity)
                        .foregroundStyle(DashboardPalette.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 9) {
                    Circle().fill(UPSAppearance.tint(for: state)).frame(width: 12, height: 12)
                    Text(statusText)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The headline plus whatever else the UPS is saying at the same time.
    private var statusText: String {
        guard let reading = state.reading else { return UPSAppearance.shortStatus(for: state) }
        let conditions = UPSStatusPresentation.conditions(for: reading.status)
        return ([UPSStatusPresentation.headline(for: reading.status)] + conditions).joined(separator: " · ")
    }
}

/// Offers a friendlier name, once, for a UPS still called by its model code
/// or NUT identifier. A name the user typed is never second-guessed.
private struct NameSuggestionRow: View {
    @EnvironmentObject private var appModel: AppModel
    @AppStorage("dismissedNameSuggestions") private var dismissed = ""

    let device: UPSDevice
    let reading: UPSReading?

    private var suggestion: String? {
        guard !dismissed.split(separator: ",").contains(Substring(device.id.uuidString)),
              UPSNaming.isRawName(device.displayName, for: device, reading: reading),
              let name = UPSNaming.suggestedName(for: reading),
              name != device.displayName
        else { return nil }
        return name
    }

    var body: some View {
        if let suggestion {
            HStack(spacing: 8) {
                Text("Call this UPS “\(suggestion)”?")
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Not Now") { dismiss() }
                Button("Rename") { appModel.rename(device, to: suggestion) }
            }
            .font(.callout)
            .accessibilityElement(children: .contain)
        }
    }

    private func dismiss() {
        dismissed = (dismissed.split(separator: ",").map(String.init) + [device.id.uuidString]).joined(separator: ",")
    }
}

/// Three balanced columns keep the primary measurements together, with power
/// consumption inside a ring representing the UPS load percentage.
private struct UPSMeasurements: View {
    let reading: UPSReading
    let isLive: Bool

    private var charge: Int? { reading.batteryCharge.flatMap { (0...100).contains($0) ? $0 : nil } }
    private var runtime: Int? { reading.batteryRuntime.flatMap { $0 >= 0 ? $0 : nil } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                metric("Battery", charge.map { "\($0)%" })
                if let charge {
                    ProgressView(value: Double(charge), total: 100)
                        .progressViewStyle(DashboardBatteryStyle(tint: batteryTint(charge: charge)))
                        .frame(height: 10)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            columnDivider

            VStack(alignment: .leading, spacing: 9) {
                metric("Estimated runtime", runtime.map { UPSTelemetry.duration(seconds: $0) })
                if runtime != nil {
                    Text(isLive ? "At current load" : "At last recorded load")
                        .foregroundStyle(DashboardPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            columnDivider

            VStack(spacing: 8) {
                metricLabel("UPS load")
                UPSLoadGauge(
                    load: reading.load,
                    power: UPSTelemetry.watts(reading) ?? UPSTelemetry.voltAmps(reading),
                    isOverloaded: reading.status.contains(.overload),
                    isLive: isLive
                )
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(isLive ? .primary : .secondary)
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(width: 1, height: 120)
            .accessibilityHidden(true)
    }

    private func metricLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(DashboardPalette.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metricLabel(title)
            Text(value ?? "Unavailable")
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private func batteryTint(charge: Int) -> Color {
        guard isLive else { return .secondary }
        if reading.status.isCritical { return .red }
        return charge < 35 && reading.status.isRunningOnBattery ? .orange : .green
    }
}

private struct DashboardBatteryStyle: ProgressViewStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.06))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                }
        }
    }
}

private struct UPSLoadGauge: View {
    let load: Int?
    let power: String?
    let isOverloaded: Bool
    let isLive: Bool

    /// The validated NUT load reading drives the arc and its accessibility value.
    private var percentage: Int? {
        load.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    var body: some View {
        ProgressView(value: Double(percentage ?? 0), total: 100)
            .progressViewStyle(UPSLoadRingStyle(tint: tint))
            .frame(width: 96, height: 96)
            .overlay {
                Group {
                    if let power {
                        Text(power)
                            .font(.system(size: 24, weight: .semibold))
                    } else {
                        Text("Unavailable")
                            .font(.system(size: 12))
                            .foregroundStyle(DashboardPalette.secondary)
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("UPS load")
            .accessibilityValue([percentage.map { "\($0) percent" } ?? "Unavailable", power].compactMap { $0 }.joined(separator: ", "))
    }

    private var tint: Color {
        guard isLive else { return .secondary }
        if isOverloaded || (percentage ?? 0) >= 95 { return .red }
        return (percentage ?? 0) >= 80 ? .orange : .green
    }
}

/// A thin determinate ring with a semantic background track.
private struct UPSLoadRingStyle: ProgressViewStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 4)
            Circle()
                .trim(from: 0, to: configuration.fractionCompleted ?? 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2)
    }
}

/// How fresh the numbers are, beside the Technical Information heading. Live
/// and stale readings must never look alike.
struct ReadingFreshness: Equatable {
    let updated: Date?
    let isLive: Bool
    let maxAge: TimeInterval

    func isFresh(at now: Date) -> Bool {
        guard isLive, let updated else { return false }
        return now.timeIntervalSince(updated) <= maxAge
    }

    func text(at now: Date) -> String {
        guard let updated else { return "No reading yet" }
        let age = max(0, Int(now.timeIntervalSince(updated)))
        let when = age < 60 ? "\(age) sec ago" : UPSTelemetry.duration(seconds: age) + " ago"
        return isFresh(at: now) ? "Updated \(when)" : "Last reading \(when) · stale"
    }
}

private struct FreshnessLabel: View {
    let updated: Date?
    let isLive: Bool
    let maxAge: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let freshness = ReadingFreshness(updated: updated, isLive: isLive, maxAge: maxAge)
            HStack(spacing: 5) {
                Text(freshness.text(at: context.date))
                Circle()
                    .fill(updated == nil ? Color.secondary : freshness.isFresh(at: context.date) ? .green : .orange)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .foregroundStyle(DashboardPalette.secondary)
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        }
    }
}

/// A small heading inside the technical disclosure, so the groups read apart
/// without nesting another container inside the form.
private struct TechnicalHeading: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DashboardPalette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Dashboard layout primitives

enum DashboardPalette {
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor
            : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.988, alpha: 1)
    })
    static let secondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .secondaryLabelColor
            : NSColor(srgbRed: 0.43, green: 0.45, blue: 0.51, alpha: 1)
    })
}


struct DashboardDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 1) }
}

extension View {
    func dashboardCard(radius: CGFloat = 12) -> some View {
        background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.055), lineWidth: 1) }
    }
}

struct DashboardRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(DashboardPalette.secondary).multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
    }
}

struct DashboardSectionHeading<Trailing: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 20)
            Text(title).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 20)
    }
}

/// Dashboard presentation only. Schedule editing and system operations remain
/// in the existing PowerScheduleView and PowerScheduleService.
private struct DashboardPowerManagementSection: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var service: PowerScheduleService
    @State private var showingSchedule = false

    var body: some View {
        VStack(spacing: 12) {
            DashboardSectionHeading(title: "Power Management", symbol: "clock") { EmptyView() }
            VStack(spacing: 0) {
                DashboardRow(title: "Restart after power failure", value: restartDescription)
                DashboardDivider().padding(.horizontal, 18)
                DashboardRow(title: scheduleTitle(isOn: true), value: summary(isOn: true))
                DashboardDivider().padding(.horizontal, 18)
                DashboardRow(title: scheduleTitle(isOn: false), value: summary(isOn: false))
            }
            .dashboardCard(radius: 10)
            HStack {
                Spacer()
                Button("Edit Schedule…") { showingSchedule = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.35)) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 17)
        .frame(minHeight: 223, alignment: .top)
        .dashboardCard()
        .sheet(isPresented: $showingSchedule) { PowerScheduleView(service: service) }
        .onAppear { service.refresh() }
    }

    private func scheduleTitle(isOn: Bool) -> String {
        guard let rule = service.schedules.first(where: { $0.action.isOn == isOn }) else {
            return isOn ? "Scheduled startup" : "Scheduled shutdown"
        }
        switch rule.action {
        case .wake: return "Scheduled wake"
        case .wakeorpoweron: return "Scheduled startup/wake"
        case .poweron: return "Scheduled startup"
        case .sleep: return "Scheduled sleep"
        case .restart: return "Scheduled restart"
        case .shutdown: return "Scheduled shutdown"
        }
    }

    private func summary(isOn: Bool) -> String {
        guard service.readError == nil else { return "Unavailable" }
        return service.schedules.first(where: { $0.action.isOn == isOn })?.summary ?? "Not scheduled"
    }

    private var restartDescription: String {
        let advice = appModel.powerProfileAdvice
        guard advice.autoRestartSupported == true, let enabled = advice.autoRestartEnabled else { return "Unavailable" }
        return enabled ? "On" : "Off"
    }
}
