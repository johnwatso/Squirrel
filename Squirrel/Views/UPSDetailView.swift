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

    /// The one vocabulary for Squirrel's link to a UPS, used by the menu,
    /// the dashboard and the device list: the UPS's own headline while
    /// connected, otherwise "Connecting…", "Not connected", "Paused" or
    /// "Not monitoring".
    static func shortStatus(for state: UPSConnectionState, isPaused: Bool = false) -> String {
        switch state {
        case .online(let reading): return UPSStatusPresentation.headline(for: reading.status)
        case .connecting: return "Connecting…"
        case .failed: return "Not connected"
        case .idle: return isPaused ? "Paused" : "Not monitoring"
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
            // One gap between every card.
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    UPSIdentityHeader(device: device, state: state, reading: reading)
                        .padding(.horizontal, 26)
                        .padding(.top, 20)
                        .padding(.bottom, 14)
                    if let reading {
                        DashboardDivider()
                        UPSMeasurements(reading: reading, isLive: isLive)
                            .padding(12)
                    }
                    NameSuggestionRow(device: device, reading: reading)
                        .padding(.horizontal, 20)
                    if let trouble = troubleMessage {
                        Label(trouble.text, systemImage: trouble.symbol)
                            .foregroundStyle(trouble.tint)
                            .font(SquirrelFont.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(20)
                    }
                }
                .dashboardCard()

                MacProtectionSection(device: device)
                DashboardPowerManagementSection(service: appModel.powerSchedule)
                technicalSection
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 33)
        }
        .font(SquirrelFont.body)
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
        case .connecting, .failed, .idle: return UPSAppearance.shortStatus(for: state, isPaused: monitor.isPaused)
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
    @State private var availableWidth: CGFloat = 0

    /// The picture's slot, sized to balance the name, model and status beside
    /// it. The drawing fits inside by its own outline, so a 2U rack fills the
    /// width and a tower fills the height. The slot takes up to 40% of the
    /// header, so it shrinks smoothly with the pane rather than in a step.
    private var illustrationSlot: CGSize {
        let width = min(168, max(110, availableWidth * 0.4))
        return CGSize(width: width, height: width * 96 / 168)
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(device.displayName)
                    .font(SquirrelFont.deviceName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(device.displayName)
                    .accessibilityAddTraits(.isHeader)
                if let identity = UPSTelemetry.identity(for: reading) {
                    Text(identity)
                        .foregroundStyle(DashboardPalette.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 9) {
                    Circle().fill(UPSAppearance.tint(for: state)).frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(statusText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Button { choosingPicture = true } label: {
                UPSDeviceIllustration(kind: device.illustration(for: reading), isTiled: false, alignment: .trailing)
                    .frame(width: illustrationSlot.width, height: illustrationSlot.height)
                    .contentShape(Rectangle())
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
        }
        .frame(minHeight: 88)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { availableWidth = $0 }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The headline plus whatever else the UPS is saying at the same time.
    private var statusText: String {
        guard let reading = state.reading else { return UPSAppearance.shortStatus(for: state, isPaused: appModel.monitor.isPaused) }
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

/// Battery and runtime share the primary panel; the smaller load panel keeps
/// percentage and power together without giving all three metrics equal weight.
private struct UPSMeasurements: View {
    let reading: UPSReading
    let isLive: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    /// Inner panels sit inside a card, so they take a second, slightly
    /// stronger layer of the same fill.
    private var panelFill: Color { Color.primary.opacity(contrast == .increased ? 0.08 : 0.04) }

    private var charge: Int? { reading.batteryCharge.flatMap { (0...100).contains($0) ? $0 : nil } }
    private var runtime: Int? { reading.batteryRuntime.flatMap { $0 >= 0 ? $0 : nil } }
    private var load: Int? { reading.load.flatMap { (0...100).contains($0) ? $0 : nil } }
    private var power: String? { UPSTelemetry.watts(reading) ?? UPSTelemetry.voltAmps(reading) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                batteryReserve
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .accessibilityHidden(true)
                runtimeEstimate
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(panelFill, in: RoundedRectangle(cornerRadius: 12))

            loadSummary
                .padding(.vertical, 12)
                .frame(width: 112)
                .frame(maxHeight: .infinity)
                .background(panelFill, in: RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(isLive ? .primary : .secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var batteryReserve: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Battery")
                .font(.body)
                .foregroundStyle(.secondary)
            Text(charge.map { "\($0)%" } ?? "Unavailable")
                .font(charge == nil ? .title3 : .largeTitle.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 34, alignment: .leading)
            if let charge {
                ProgressView(value: Double(charge), total: 100)
                    .progressViewStyle(BatteryReserveStyle(tint: batteryTint))
                    .frame(height: 6)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(charge.map { "\($0) percent" } ?? "Unavailable")
    }

    private var runtimeEstimate: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Estimated runtime")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(runtime.map { UPSTelemetry.duration(seconds: $0) } ?? "Unavailable")
                .font(runtime == nil ? .title3 : .title.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 34, alignment: .leading)
            Text(runtime == nil ? "Not reported by UPS" : (isLive ? "At current load" : "At last recorded load"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var loadSummary: some View {
        VStack(spacing: 8) {
            Label("UPS load", systemImage: "powerplug")
                .font(.callout)
                .foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .stroke(Color(nsColor: .quaternaryLabelColor), lineWidth: 5)
                if let load {
                    Circle()
                        .trim(from: 0, to: Double(load) / 100)
                        .stroke(loadTint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 2) {
                    Text(load.map { "\($0)%" } ?? "Unavailable")
                        .font(load == nil ? .caption : .title2.weight(.semibold))
                    Text(power ?? "Power unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
            }
            .padding(3)
            .frame(width: 84, height: 84)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLive ? "UPS load and power" : "Last recorded UPS load and power")
        .accessibilityValue([load.map { "\($0) percent load" } ?? "Load unavailable", power ?? "Power unavailable"].joined(separator: ", "))
    }

    private var batteryTint: Color {
        guard isLive else { return .secondary }
        if reading.status.isCritical { return .red }
        return (charge ?? 100) < 35 && reading.status.isRunningOnBattery ? .orange : .green
    }

    private var loadTint: Color {
        guard isLive, load != nil else { return .secondary }
        if reading.status.contains(.overload) || (load ?? 0) >= 95 { return .red }
        return (load ?? 0) >= 80 ? .orange : .green
    }
}

/// A quiet horizontal indicator of remaining battery charge.
private struct BatteryReserveStyle: ProgressViewStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color(nsColor: .quaternaryLabelColor))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                }
        }
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
            .font(SquirrelFont.caption)
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
    /// Secondary text, from the system palette so it follows light, dark
    /// and Increase Contrast.
    static let secondary = Color(nsColor: .secondaryLabelColor)
}

/// A hairline between rows, in the system separator colour.
struct DashboardDivider: View {
    var body: some View { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
}

/// A grouped card: a faint fill that strengthens under Increase Contrast,
/// edged in the system separator colour.
private struct DashboardCard: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(contrast == .increased ? 0.07 : 0.03))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
    }
}

extension View {
    func dashboardCard(radius: CGFloat = 12) -> some View {
        modifier(DashboardCard(radius: radius))
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
            Text(title).font(SquirrelFont.cardHeading).accessibilityAddTraits(.isHeader)
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
                // A standard push button, like "Share with macOS" above.
                Button("Edit Schedule…") { showingSchedule = true }
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
