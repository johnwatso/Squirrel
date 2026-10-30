import Charts
import SquirrelCore
import SwiftUI

/// One measurement a history chart can plot. Each knows how to read itself
/// out of a sample and how to write its values, so the charts stay generic.
enum HistoryMetric: String, CaseIterable, Identifiable {
    case power
    case load
    case charge
    case runtime
    case temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .power: return "Power"
        case .load: return "UPS Load"
        case .charge: return "Battery Charge"
        case .runtime: return "Estimated Runtime"
        case .temperature: return "Temperature"
        }
    }

    func value(_ sample: PowerSample) -> Double? {
        switch self {
        case .power: return sample.power
        case .load: return sample.load
        case .charge: return sample.charge
        // Plotted in minutes: an axis reading "3,600" helps nobody.
        case .runtime: return sample.runtime.map { $0 / 60 }
        case .temperature: return sample.temperature
        }
    }

    /// A second line on the same axis. Only temperature has one: this Mac's
    /// chip, so a hot cupboard shows up in both.
    func comparisonValue(_ sample: PowerSample) -> Double? {
        self == .temperature ? sample.macTemperature : nil
    }

    /// What each line is called, when there are two.
    var lineNames: (primary: String, comparison: String)? {
        self == .temperature ? ("UPS", "This Mac") : nil
    }

    func hasData(in samples: [PowerSample]) -> Bool {
        samples.contains { value($0) != nil || comparisonValue($0) != nil }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .power: return "\(Int(value.rounded())) W"
        case .load, .charge: return "\(Int(value.rounded()))%"
        case .runtime: return UPSTelemetry.duration(seconds: Int(value * 60))
        case .temperature: return "\(Int(value.rounded())) °C"
        }
    }

    /// A short summary of the range: what people actually ask of a chart.
    func summary(_ samples: [PowerSample]) -> String? {
        if let names = lineNames {
            let parts = [(names.primary, samples.compactMap(value)), (names.comparison, samples.compactMap(comparisonValue))]
                .filter { !$0.1.isEmpty }
                .map { name, values in "\(name) average \(format(values.reduce(0, +) / Double(values.count)))" }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        let values = samples.compactMap(value)
        guard !values.isEmpty else { return nil }
        let average = values.reduce(0, +) / Double(values.count)
        switch self {
        case .power, .load, .temperature:
            return "Average \(format(average)) · Peak \(format(values.max() ?? average))"
        case .charge, .runtime:
            return "Lowest \(format(values.min() ?? average))"
        }
    }

    var fixedDomain: ClosedRange<Double>? {
        switch self {
        case .charge: return 0...100
        case .power, .load, .runtime, .temperature: return nil
        }
    }

    /// A temperature axis from zero would flatten every change into a line.
    var includesZero: Bool { self != .temperature }
}

/// A line over time, with outages shaded behind it.
struct HistoryChart: View {
    let samples: [PowerSample]
    let metric: HistoryMetric
    let range: HistoryRange
    var compact = false
    var events: [PowerEvent] = []

    var body: some View {
        chart
            .chartXScale(domain: Date().addingTimeInterval(-range.duration)...Date())
            .chartYAxis(compact ? .hidden : .automatic)
            .chartXAxis(compact ? .hidden : .automatic)
            .accessibilityElement()
            .accessibilityLabel("\(metric.title) over the last \(range.title.lowercased())")
            .accessibilityValue(metric.summary(samples) ?? "No data")
    }

    /// Grey bands distinguish missing recordings from a measured zero.
    private var missingPeriods: [ClosedRange<Date>] {
        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        var cursor = start
        var gaps: [ClosedRange<Date>] = []
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            guard sample.date >= start, sample.date <= end else { continue }
            if sample.date.timeIntervalSince(cursor) > range.bucket * 2.5 {
                gaps.append(cursor...sample.date)
            }
            cursor = sample.date.addingTimeInterval(range.bucket)
        }
        if end.timeIntervalSince(cursor) > range.bucket * 2.5 {
            gaps.append(cursor...end)
        }
        return gaps
    }

    @ChartContentBuilder
    private var outageMarks: some ChartContent {
        ForEach(samples.filter(\.onBattery)) { sample in
            RectangleMark(
                xStart: .value("Start", sample.date),
                xEnd: .value("End", sample.date.addingTimeInterval(range.bucket))
            )
            .foregroundStyle(Color.orange.opacity(0.15))
        }
    }

    private typealias Point = (date: Date, value: Double, segment: Int, isolated: Bool)

    /// Points to plot, split into runs wherever Squirrel was not recording.
    /// A line drawn across a night the Mac was off would invent a reading.
    private func points(_ value: (PowerSample) -> Double?) -> [Point] {
        var result: [Point] = []
        var segment = 0
        var previous: Date?
        for sample in samples {
            guard let value = value(sample) else { previous = nil; continue }
            if let previous, sample.date.timeIntervalSince(previous) <= range.bucket * 2.5 {
                // Same run.
            } else {
                segment += 1
            }
            result.append((sample.date, value, segment, false))
            previous = sample.date
        }
        // A run of one has no line to draw, so it is shown as a dot.
        let counts = Dictionary(grouping: result, by: \.segment).mapValues(\.count)
        return result.map { ($0.date, $0.value, $0.segment, counts[$0.segment] == 1) }
    }

    /// Distinct from the accent in both appearances, and from the orange of
    /// outages.
    static let comparisonColor = Color.purple

    @ChartContentBuilder
    private func line(_ points: [Point], name: String, color: Color) -> some ChartContent {
        ForEach(points, id: \.date) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value(metric.title, point.value),
                series: .value("Run", "\(name) \(point.segment)")
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 1.75))
            .foregroundStyle(color)
            .accessibilityLabel(name)
            if point.isolated {
                PointMark(x: .value("Time", point.date), y: .value(metric.title, point.value))
                    .symbolSize(compact ? 12 : 20)
                    .foregroundStyle(color)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        let base = Chart {
            ForEach(missingPeriods, id: \.lowerBound) { gap in
                RectangleMark(
                    xStart: .value("No readings from", gap.lowerBound),
                    xEnd: .value("No readings until", gap.upperBound)
                )
                .foregroundStyle(Color.secondary.opacity(0.12))
                .accessibilityLabel("No recorded readings")
            }
            outageMarks
            ForEach(events) { event in
                RuleMark(x: .value("Event", event.date))
                    .foregroundStyle(event.kind == .lowBattery ? Color.red.opacity(0.65) : Color.orange.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 2) {
                        Image(systemName: event.kind.symbolName)
                            .font(.caption2)
                            .help(event.kind.title + " · " + event.kind.provenance)
                    }
                    .accessibilityLabel(event.kind.title + " · " + event.kind.provenance)
            }
            line(points(metric.value), name: metric.lineNames?.primary ?? metric.title, color: .accentColor)
            if let names = metric.lineNames {
                line(points(metric.comparisonValue), name: names.comparison, color: Self.comparisonColor)
            }
        }
        if let domain = metric.fixedDomain {
            base.chartYScale(domain: domain)
        } else if !metric.includesZero {
            base.chartYScale(domain: .automatic(includesZero: false))
        } else {
            base
        }
    }
}

// MARK: - History window

/// The full history: a chart for each measurement this UPS reports, and the
/// event log underneath. Its own window, so browsing history never blocks
/// the dashboard.
struct PowerHistoryView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var history: PowerHistory

    @AppStorage("historyRange") private var range: HistoryRange = .day
    @State private var samples: [PowerSample] = []
    @State private var events: [PowerEvent] = []
    @State private var recentEvents: [PowerEvent] = []
    @State private var hasLoaded = false
    @State private var loadedDeviceID: UUID?
    @State private var loadedRange: HistoryRange?

    private var device: UPSDevice? {
        appModel.historyDeviceID.flatMap(settings.device(id:)) ?? appModel.primaryDevice
    }

    private var metrics: [HistoryMetric] {
        HistoryMetric.allCases.filter { $0.hasData(in: samples) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if history.isAvailable, hasLoaded, loadedDeviceID == device?.id, loadedRange == range {
                PowerHistorySummary(events: recentEvents)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 700)
        .task(id: LoadKey(device: device?.id, range: range, revision: history.revision)) {
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The window title already says UPS History.
            Text(device.map { "Readings and events for \($0.displayName)." }
                 ?? "Readings and events for your UPS.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if settings.devices.count > 1 {
                    Picker("UPS", selection: deviceSelection) {
                        ForEach(settings.devices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel("UPS")
                    .help("Choose which UPS to show")
                }
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("History range")
                .help("Choose how far back to show")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if device == nil {
            HistoryPlaceholder(title: "No UPS", message: "Set up a UPS to start recording its history.")
        } else if !history.isAvailable {
            HistoryPlaceholder(title: "History Unavailable", message: "Squirrel could not open its history file.")
        } else if !hasLoaded || loadedDeviceID != device?.id || loadedRange != range {
            ProgressView("Loading history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if samples.isEmpty && events.isEmpty {
            HistoryPlaceholder(
                title: "No History Yet",
                message: "Squirrel records readings once a minute while it is running. Check back in a few minutes."
            )
        } else {
            Form {
                if let first = samples.first {
                    Section {
                        Text("Readings in this view since \(first.date.formatted(date: .abbreviated, time: .shortened))")
                        Text("Collecting history while Squirrel runs. Grey bands have no recorded readings; gaps are not zero values.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(metrics) { metric in
                    Section {
                        HistoryChart(samples: samples, metric: metric, range: range, events: metric == .power ? events : [])
                            .frame(height: 110)
                            .padding(.vertical, 4)
                        if let names = metric.lineNames {
                            HStack(spacing: 14) {
                                LineKey(name: names.primary, color: .accentColor)
                                LineKey(name: names.comparison, color: HistoryChart.comparisonColor)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Text(metric.title)
                            Spacer()
                            if let summary = metric.summary(samples) {
                                Text(summary)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }
                    }
                }

                Section {
                    if events.isEmpty {
                        Text("No events in the last \(range.title.lowercased()).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events) { event in
                            EventRow(event: event)
                        }
                    }
                } header: {
                    Text("Recent Events")
                } footer: {
                    if samples.contains(where: \.onBattery) {
                        Label("Shaded periods are when the UPS was on battery.", systemImage: "square.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.orange.opacity(0.4), .secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var deviceSelection: Binding<UUID?> {
        Binding(
            get: { device?.id },
            set: { appModel.historyDeviceID = $0 }
        )
    }

    private func load() async {
        guard let device else { return }
        let requestedID = device.id
        let requestedRange = range
        let now = Date()
        let since = now.addingTimeInterval(-requestedRange.duration)
        let nextSamples = await history.samples(for: requestedID, in: requestedRange)
        let nextEvents = await history.events(for: requestedID, since: since)
        let nextRecentEvents = await history.events(
            for: requestedID, since: now.addingTimeInterval(-HistoryRange.day.duration), limit: -1
        )
        // A cancelled load must never put one UPS's history beneath another's name.
        guard !Task.isCancelled, self.device?.id == requestedID, range == requestedRange else { return }
        samples = nextSamples
        events = nextEvents
        recentEvents = nextRecentEvents
        loadedDeviceID = requestedID
        loadedRange = requestedRange
        hasLoaded = true
    }

    private struct LoadKey: Equatable {
        let device: UUID?
        let range: HistoryRange
        let revision: Int
    }
}

/// A fixed daily overview, independent of the graph's selected date range.
private struct PowerHistorySummary: View {
    let events: [PowerEvent]

    var body: some View {
        HStack(spacing: 0) {
            Text("Last 24 hours")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)

            metric(symbol: "bolt.slash.fill", color: .orange, kind: .powerLost, label: "Outages")
            Divider().frame(height: 28)
            metric(symbol: "arrow.triangle.2.circlepath", color: .blue,
                   kind: .communicationRestored, label: "Reconnects")
            Divider().frame(height: 28)
            metric(symbol: "battery.25percent", color: .red, kind: .lowBattery, label: "Low battery")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }

    private func metric(symbol: String, color: Color, kind: PowerEventKind, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(events.filter { $0.kind == kind }.count)")
                    .font(.headline.monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Which colour is which line, for a chart that has two.
private struct LineKey: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 3)
                .accessibilityHidden(true)
            Text(name)
        }
    }
}

private struct EventRow: View {
    let event: PowerEvent

    var body: some View {
        LabeledContent {
            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                .monospacedDigit()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.kind.title)
                    Text(event.kind.provenance).font(.caption2).foregroundStyle(.secondary)
                    if let detail = event.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: event.kind.symbolName)
                    .foregroundStyle(tint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch event.kind {
        case .powerLost, .communicationLost, .connectionUnstable: return .orange
        case .lowBattery: return .red
        case .powerRestored, .communicationRestored: return .blue
        case .scheduleChanged, .systemWake, .systemSleep, .systemShutdown: return .purple
        case .monitoringStarted, .monitoringPaused, .monitoringResumed, .monitoringStopped: return .secondary
        }
    }
}

/// An empty state in the system's own voice. `ContentUnavailableView` is
/// macOS 14; Squirrel still runs on 13.
struct HistoryPlaceholder: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
