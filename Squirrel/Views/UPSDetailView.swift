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
/// A native grouped form kept deliberately short, so a default-sized window
/// shows all of it without scrolling. Only the two numbers that matter in an
/// outage are large; the rows that appear are the ones this UPS reports.
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
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    UPSIdentityHeader(device: device, state: state, reading: reading)
                    if let reading {
                        UPSMeasurements(reading: reading, isLive: isLive)
                    }
                }
                .padding(.vertical, 4)

                NameSuggestionRow(device: device, reading: reading)

                if let trouble = troubleMessage {
                    Label(trouble.text, systemImage: trouble.symbol)
                        .foregroundStyle(trouble.tint)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            MacProtectionSection(device: device)
            technicalSection
        }
        .formStyle(.grouped)
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
        Section {
            DisclosureRow("Technical Information", isExpanded: $settings.preferences.technicalInfoExpanded) {
                technicalRows
            } trailing: {
                FreshnessLabel(updated: monitor.lastUpdated[device.id], isLive: isLive, maxAge: settings.preferences.readingMaxAge)
            }
        }
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
                .foregroundStyle(.secondary)
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
    let device: UPSDevice
    let state: UPSConnectionState
    let reading: UPSReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(device.displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            if let identity = UPSTelemetry.identity(for: reading) {
                Text(identity)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            StatusBadge(title: statusText, tint: UPSAppearance.tint(for: state))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Two measurement rows with matching equal-width columns. Measuring the available
/// width keeps both HStacks aligned without imposing a fixed content height.
private struct UPSMeasurements: View {
    let reading: UPSReading
    let isLive: Bool
    @State private var contentWidth: CGFloat = 0

    private var leftColumnWidth: CGFloat? {
        contentWidth > 20 ? (contentWidth - 20) * 0.5 : nil
    }

    private var charge: Int? {
        reading.batteryCharge.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    private var runtime: Int? {
        reading.batteryRuntime.flatMap { $0 >= 0 ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                metric("Battery", charge.map { "\($0)%" }) {
                    if let charge {
                        ProgressView(value: Double(charge), total: 100)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(batteryTint(charge: charge))
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: leftColumnWidth, alignment: .leading)

                metric("Estimated runtime", runtime.map { UPSTelemetry.duration(seconds: $0) }) {
                    if runtime != nil {
                        Text(isLive ? "At current load" : "At last recorded load")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack(alignment: .center, spacing: 20) {
                metric("Power consumption", UPSTelemetry.watts(reading) ?? UPSTelemetry.voltAmps(reading)) {
                    EmptyView()
                }
                .frame(width: leftColumnWidth, alignment: .leading)

                HStack(alignment: .center) {
                    Text("UPS load")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    UPSLoadGauge(load: reading.load, isOverloaded: reading.status.contains(.overload), isLive: isLive)
                        .frame(width: 44, height: 44)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(isLive ? .primary : .secondary)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: MeasurementWidthKey.self, value: geometry.size.width)
            }
        }
        .onPreferenceChange(MeasurementWidthKey.self) { contentWidth = $0 }
    }

    private func metric<Accessory: View>(
        _ title: String,
        _ value: String?,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "Unavailable")
                .font(.title2.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func batteryTint(charge: Int) -> Color {
        guard isLive else { return .secondary }
        if reading.status.isCritical { return .red }
        return charge < 35 && reading.status.isRunningOnBattery ? .orange : .green
    }
}

private struct MeasurementWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct UPSLoadGauge: View {
    let load: Int?
    let isOverloaded: Bool
    let isLive: Bool

    /// The same validated NUT reading drives the arc and its sole value label.
    private var percentage: Int? {
        load.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    var body: some View {
        Group {
            if let percentage {
                ProgressView(value: Double(percentage), total: 100)
                    .progressViewStyle(UPSLoadRingStyle(tint: tint))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text("\(percentage)%")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 5)
                    }
            } else {
                Text("Unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("UPS load")
        .accessibilityValue(percentage.map { "\($0) percent" } ?? "Unavailable")
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
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: configuration.fractionCompleted ?? 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
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
            .font(.caption)
            .foregroundStyle(.secondary)
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
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}
