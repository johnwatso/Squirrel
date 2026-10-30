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
    /// The reading under the pointer, shown as a callout.
    @State private var hovered: PowerSample?

    var body: some View {
        chart
            .chartXScale(domain: Date().addingTimeInterval(-range.duration)...Date())
            .chartOverlay { proxy in
                if !compact { hoverLayer(proxy) }
            }
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

    // MARK: Hover

    /// Tracks the pointer over the plot and draws the callout beside the
    /// selected reading, on whichever side has room.
    private func hoverLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            let plot = geometry[proxy.plotAreaFrame]
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let date: Date? = proxy.value(atX: location.x - plot.minX)
                            let next = date.flatMap { Self.nearest(to: $0, in: samples, metric: metric, within: range.bucket * 1.5) }
                            if next != hovered { hovered = next }
                        case .ended:
                            hovered = nil
                        }
                    }
                if let hovered, let x = proxy.position(forX: hovered.date) {
                    let position = plot.minX + x
                    if position < geometry.size.width / 2 {
                        callout(for: hovered)
                            .offset(x: position + 8, y: plot.minY + 2)
                    } else {
                        callout(for: hovered)
                            .frame(width: max(0, position - 8), alignment: .trailing)
                            .offset(y: plot.minY + 2)
                    }
                }
            }
        }
    }

    private func callout(for sample: PowerSample) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(range == .day
                 ? sample.date.formatted(date: .omitted, time: .shortened)
                 : sample.date.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
            if let names = metric.lineNames {
                calloutRow(names.primary, metric.value(sample), color: .accentColor)
                calloutRow(names.comparison, metric.comparisonValue(sample), color: Self.comparisonColor)
            } else if let value = metric.value(sample) {
                Text(metric.format(value)).fontWeight(.semibold)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .fixedSize()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func calloutRow(_ name: String, _ value: Double?, color: Color) -> some View {
        if let value {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name)
                Spacer(minLength: 8)
                Text(metric.format(value)).fontWeight(.semibold)
            }
        }
    }

    /// The reading closest to `date` that has something to show, or nil in a
    /// gap: a callout must never invent a value where none was recorded.
    static func nearest(to date: Date, in samples: [PowerSample], metric: HistoryMetric, within limit: TimeInterval) -> PowerSample? {
        samples
            .filter { metric.value($0) != nil || metric.comparisonValue($0) != nil }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            .flatMap { abs($0.date.timeIntervalSince(date)) <= limit ? $0 : nil }
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
            if let hovered {
                RuleMark(x: .value("Selected", hovered.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if let value = metric.value(hovered) {
                    PointMark(x: .value("Time", hovered.date), y: .value(metric.title, value))
                        .symbolSize(36)
                        .foregroundStyle(Color.accentColor)
                }
                if let value = metric.comparisonValue(hovered) {
                    PointMark(x: .value("Time", hovered.date), y: .value(metric.title, value))
                        .symbolSize(36)
                        .foregroundStyle(Self.comparisonColor)
                }
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
    @State private var expandedEventIDs: Set<PowerEvent.ID> = []

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
            // One scroll view with Otter's 16-point margins, so the summary
            // above, the charts and the events all share the same edges.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let first = samples.first {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Readings since \(first.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline)
                            Text("Grey bands have no recorded readings; gaps are not zero values.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                    ForEach(metrics) { metric in
                        chartCard(metric)
                    }
                    if samples.contains(where: \.onBattery) {
                        Label("Shaded periods are when the UPS was on battery.", systemImage: "square.fill")
                            .font(.caption)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.orange.opacity(0.4), .secondary)
                            .padding(.horizontal, 4)
                    }

                    Text("Events")
                        .font(.headline)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    if events.isEmpty {
                        Text("No events in the last \(range.title.lowercased()).")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .historyCard()
                    } else {
                        ForEach(EventDay.days(from: events)) { day in
                            EventDaySection(day: day, expandedIDs: $expandedEventIDs)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func chartCard(_ metric: HistoryMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let summary = metric.summary(samples) {
                    Text(summary)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HistoryChart(samples: samples, metric: metric, range: range, events: metric == .power ? events : [])
                .frame(height: 110)
            if let names = metric.lineNames {
                HStack(spacing: 14) {
                    LineKey(name: names.primary, color: .accentColor)
                    LineKey(name: names.comparison, color: HistoryChart.comparisonColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .historyCard()
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

/// Otter's card: a quiet fill and a hairline edge, shared by every block in
/// the history window so they line up.
private extension View {
    func historyCard() -> some View {
        background(.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// One calendar day of events, newest first.
private struct EventDay: Identifiable {
    let day: Date
    let runs: [EventRun]
    var id: Date { day }

    static func days(from events: [PowerEvent]) -> [EventDay] {
        let calendar = Calendar.current
        return Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
            .map { EventDay(day: $0.key, runs: EventRun.runs(from: $0.value.sorted { $0.date > $1.date })) }
            .sorted { $0.day > $1.day }
    }
}

/// Back-to-back events of one kind with the same detail, shown as one row:
/// a run of restarts is one fact, not a screenful.
struct EventRun: Identifiable {
    let events: [PowerEvent]
    var id: PowerEvent.ID { events[0].id }

    /// `events` newest first.
    static func runs(from events: [PowerEvent]) -> [EventRun] {
        var result: [[PowerEvent]] = []
        for event in events {
            if let last = result.last?.first, last.kind == event.kind, last.detail == event.detail {
                result[result.count - 1].append(event)
            } else {
                result.append([event])
            }
        }
        return result.map(EventRun.init)
    }
}

private struct EventDaySection: View {
    let day: EventDay
    @Binding var expandedIDs: Set<PowerEvent.ID>

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(day.runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 {
                    // Inset to the text, past the icon column.
                    Divider().padding(.leading, 46)
                }
                EventRow(events: run.events, isExpanded: expandedIDs.contains(run.id)) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedIDs.remove(run.id) == nil { expandedIDs.insert(run.id) }
                    }
                }
            }
        }
        .historyCard()
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let name = relativeName {
                Text(name).fontWeight(.semibold)
                Text(day.day.formatted(date: .long, time: .omitted)).foregroundStyle(.secondary)
            } else {
                Text(day.day.formatted(date: .long, time: .omitted)).fontWeight(.semibold)
            }
            Spacer()
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6))
        .accessibilityAddTraits(.isHeader)
    }

    private var relativeName: String? {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.day) { return "Today" }
        if calendar.isDateInYesterday(day.day) { return "Yesterday" }
        return nil
    }
}

private struct EventRow: View {
    let events: [PowerEvent]
    let isExpanded: Bool
    let toggle: () -> Void

    private var event: PowerEvent { events[0] }
    private var isRun: Bool { events.count > 1 }

    private var title: String {
        isRun ? "\(event.kind.title) ×\(events.count)" : event.kind.title
    }

    private var timeLabel: String {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        guard isRun, let oldest = events.last else { return time(event.date) }
        let start = time(oldest.date)
        let end = time(event.date)
        return start == end ? end : "\(start) – \(end)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: event.kind.symbolName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(event.kind.tint)
                        .frame(width: 20)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let detail = event.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(timeLabel)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows event details")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                details
                    .padding(.leading, 46)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }

    private var accessibilityText: String {
        var text = event.kind.title
        if isRun {
            text += ", \(events.count) times, \(timeLabel)"
        } else {
            text += ", \(event.date.formatted(date: .abbreviated, time: .shortened))"
        }
        if let detail = event.detail, !detail.isEmpty { text += ", \(detail)" }
        return text
    }

    /// What used to crowd every row, kept for whoever asks. The detail is
    /// already above, unclamped once expanded.
    private var details: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("Source", event.kind.provenance)
            if isRun {
                row("Times", events.map { $0.date.formatted(date: .omitted, time: .standard) }.joined(separator: "\n"))
            } else {
                row("Time", event.date.formatted(date: .long, time: .standard))
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension PowerEventKind {
    var tint: Color {
        switch self {
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
