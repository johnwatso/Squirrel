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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .power: return "Power"
        case .load: return "UPS Load"
        case .charge: return "Battery Charge"
        case .runtime: return "Estimated Runtime"
        }
    }

    func value(_ sample: PowerSample) -> Double? {
        switch self {
        case .power: return sample.power
        case .load: return sample.load
        case .charge: return sample.charge
        // Plotted in minutes: an axis reading "3,600" helps nobody.
        case .runtime: return sample.runtime.map { $0 / 60 }
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .power: return "\(Int(value.rounded())) W"
        case .load, .charge: return "\(Int(value.rounded()))%"
        case .runtime: return UPSTelemetry.duration(seconds: Int(value * 60))
        }
    }

    /// A short summary of the range: what people actually ask of a chart.
    func summary(_ samples: [PowerSample]) -> String? {
        let values = samples.compactMap(value)
        guard !values.isEmpty else { return nil }
        let average = values.reduce(0, +) / Double(values.count)
        switch self {
        case .power, .load:
            return "Average \(format(average)) · Peak \(format(values.max() ?? average))"
        case .charge, .runtime:
            return "Lowest \(format(values.min() ?? average))"
        }
    }

    var fixedDomain: ClosedRange<Double>? {
        switch self {
        case .charge: return 0...100
        case .power, .load, .runtime: return nil
        }
    }
}

/// A line over time, with outages shaded behind it.
struct HistoryChart: View {
    let samples: [PowerSample]
    let metric: HistoryMetric
    let range: HistoryRange
    var compact = false

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

    /// Points to plot, split into runs wherever Squirrel was not recording.
    /// A line drawn across a night the Mac was off would invent a reading.
    private var points: [(date: Date, value: Double, segment: Int, isolated: Bool)] {
        var result: [(date: Date, value: Double, segment: Int, isolated: Bool)] = []
        var segment = 0
        var previous: Date?
        for sample in samples {
            guard let value = metric.value(sample) else { previous = nil; continue }
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
            ForEach(points, id: \.date) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value(metric.title, point.value),
                    series: .value("Run", point.segment)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 1.75))
                if point.isolated {
                    PointMark(x: .value("Time", point.date), y: .value(metric.title, point.value))
                        .symbolSize(compact ? 12 : 20)
                }
            }
        }
        .foregroundStyle(Color.accentColor)
        if let domain = metric.fixedDomain {
            base.chartYScale(domain: domain)
        } else {
            base
        }
    }
}

// MARK: - Preview in the main window

/// A quiet strip in the main window: the last day of power at a glance, and
/// the most recent event. The full history lives in its own window.
struct PowerHistoryPreviewSection: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var history: PowerHistory

    let device: UPSDevice

    @State private var samples: [PowerSample] = []
    @State private var latestEvent: PowerEvent?
    @State private var hasLoaded = false

    /// Power if the UPS reports it, load if not, charge as a last resort.
    private var metric: HistoryMetric? {
        [.power, .load, .charge].first { metric in samples.contains { metric.value($0) != nil } }
    }

    var body: some View {
        Section {
            if let metric {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(metric.title)
                        Spacer()
                        if let summary = metric.summary(samples) {
                            Text(summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    HistoryChart(samples: samples, metric: metric, range: .day, compact: true)
                        .frame(height: 56)
                }
                .padding(.vertical, 2)
            } else if hasLoaded {
                Text("Squirrel records history while it runs. A chart appears here after a few minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let latestEvent {
                LabeledContent {
                    Text(latestEvent.date, format: .relative(presentation: .named))
                } label: {
                    Label(latestEvent.kind.title, systemImage: latestEvent.kind.symbolName)
                }
            }

            Button("Show Power History…") { appModel.showHistory(for: device) }
        } header: {
            HStack {
                Text("Power History")
                Spacer()
                Text("Last 24 hours")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .task(id: LoadKey(device: device.id, revision: history.revision)) {
            samples = await history.samples(for: device.id, in: .day)
            latestEvent = await history.events(for: device.id, limit: 1).first
            hasLoaded = true
        }
    }

    private struct LoadKey: Equatable {
        let device: UUID
        let revision: Int
    }
}

// MARK: - History window

/// The full history: a chart for each measurement this UPS reports, and the
/// event log underneath.
struct PowerHistoryWindow: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var history: PowerHistory

    @AppStorage("historyRange") private var range: HistoryRange = .day
    @State private var samples: [PowerSample] = []
    @State private var events: [PowerEvent] = []
    @State private var hasLoaded = false
    @State private var loadedDeviceID: UUID?
    @State private var loadedRange: HistoryRange?

    private var device: UPSDevice? {
        appModel.historyDeviceID.flatMap(settings.device(id:)) ?? appModel.primaryDevice
    }

    private var metrics: [HistoryMetric] {
        HistoryMetric.allCases.filter { metric in samples.contains { metric.value($0) != nil } }
    }

    var body: some View {
        content
            .frame(minWidth: 460, minHeight: 360)
            .navigationTitle("Power History")
            .navigationSubtitle(device?.displayName ?? "")
            .toolbar {
                ToolbarItemGroup {
                    if settings.devices.count > 1 {
                        Picker("UPS", selection: deviceSelection) {
                            ForEach(settings.devices) { device in
                                Text(device.displayName).tag(Optional(device.id))
                            }
                        }
                        .help("Choose which UPS to show")
                    }
                    Picker("Range", selection: $range) {
                        ForEach(HistoryRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Choose how far back to show")
                }
            }
            .task(id: LoadKey(device: device?.id, range: range, revision: history.revision)) {
                await load()
            }
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
                        HistoryChart(samples: samples, metric: metric, range: range)
                            .frame(height: 110)
                            .padding(.vertical, 4)
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
                        Text("No power events in the last \(range.title.lowercased()).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events) { event in
                            EventRow(event: event)
                        }
                    }
                } header: {
                    Text("Events")
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
        let since = Date().addingTimeInterval(-requestedRange.duration)
        let nextSamples = await history.samples(for: requestedID, in: requestedRange)
        let nextEvents = await history.events(for: requestedID, since: since)
        // A cancelled load must never put one UPS's history beneath another's name.
        guard !Task.isCancelled, self.device?.id == requestedID, range == requestedRange else { return }
        samples = nextSamples
        events = nextEvents
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
        case .powerLost, .communicationLost: return .orange
        case .lowBattery: return .red
        case .powerRestored, .communicationRestored: return .secondary
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
