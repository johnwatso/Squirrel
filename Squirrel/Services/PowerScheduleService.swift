import AppKit
import Foundation
import IOKit.pwr_mgt

/// The two recurring slots belong to macOS, not to a particular UPS.
struct RepeatingPowerSchedule: Identifiable, Equatable, Codable, Sendable {
    enum Action: String, CaseIterable, Codable, Sendable {
        case wake, wakeorpoweron, poweron, sleep, restart, shutdown
        var title: String {
            switch self {
            case .wake: return "Wake"
            case .wakeorpoweron: return "Start or Wake"
            case .poweron: return "Start Up"
            case .sleep: return "Sleep"
            case .restart: return "Restart"
            case .shutdown: return "Shut Down"
            }
        }
        var isOn: Bool { self == .wake || self == .wakeorpoweron || self == .poweron }
        var symbol: String { isOn ? "sun.max.fill" : self == .sleep ? "moon.fill" : self == .restart ? "arrow.clockwise" : "power" }
    }
    var action: Action
    var minutes: Int
    var days: Int
    var enabled = true
    var id: String { action.isOn ? "on" : "off" }
    static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    var dayArguments: String {
        zip(Array("MTWRFSU"), 0..<7).compactMap { days & (1 << $0.1) != 0 ? String($0.0) : nil }.joined()
    }
    var timeArgument: String { String(format: "%02d:%02d:00", minutes / 60, minutes % 60) }
    var summary: String {
        guard enabled else { return "Disabled" }
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        let dayText = days == 127 ? "Every day" : days == 31 ? "Weekdays" : days == 96 ? "Weekends" :
            (0..<7).filter { days & (1 << $0) != 0 }.map { Self.dayNames[$0] }.joined(separator: ", ")
        return "\(dayText) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    static func arguments(for schedules: [Self]) throws -> [String] {
        let active = schedules.filter(\.enabled)
        guard schedules.count <= 2, Set(schedules.map(\.id)).count == schedules.count,
              schedules.allSatisfy({ (0..<1440).contains($0.minutes) && (1...127).contains($0.days) }) else {
            throw ScheduleError.invalid("macOS allows one startup/wake rule and one sleep, restart or shutdown rule. Select at least one day for each rule.")
        }
        return active.isEmpty ? ["repeat", "cancel"] : ["repeat"] + active.flatMap { [$0.action.rawValue, $0.dayArguments, $0.timeArgument] }
    }
}

enum ScheduleError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct ScheduledSystemEvent: Identifiable, Sendable {
    let date: Date
    let type: String
    let owner: String
    var id: String { "\(date.timeIntervalSince1970)|\(type)|\(owner)" }
    var title: String { RepeatingPowerSchedule.Action(rawValue: type == "wakepoweron" ? "wakeorpoweron" : type)?.title ?? type }
}

@MainActor
final class PowerScheduleService: ObservableObject {
    @Published private(set) var schedules: [RepeatingPowerSchedule] = []
    @Published private(set) var scheduledEvents: [ScheduledSystemEvent] = []
    @Published private(set) var readError: String?
    @Published private(set) var isApplying = false
    @Published private(set) var lastError: String?
    private(set) var baseline = ""
    private let defaults: UserDefaults
    private let reader: ([String]) throws -> String
    private let writer: ([String], String?) async throws -> Void
    private static let draftKey = "disabledPowerScheduleDrafts"

    init(defaults: UserDefaults = .standard,
         reader: (([String]) throws -> String)? = nil,
         writer: (([String], String?) async throws -> Void)? = nil) {
        self.defaults = defaults
        self.reader = reader ?? { try Self.pmset($0) }
        self.writer = writer ?? { try await Self.authorizePMSet($0, expectedSchedule: $1) }
    }

    func refresh() {
        do {
            let output = try reader(["-g", "sched"])
            let active = try Self.parse(output)
            let disabled = defaults.data(forKey: Self.draftKey).flatMap { try? JSONDecoder().decode([RepeatingPowerSchedule].self, from: $0) } ?? []
            schedules = active + disabled.filter { !$0.enabled && !active.map(\.id).contains($0.id) }
            baseline = output
            readError = nil
        } catch {
            readError = error.localizedDescription
        }
        let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] ?? []
        scheduledEvents = events.compactMap { entry in
            guard let date = entry["time"] as? Date, let type = entry["eventtype"] as? String else { return nil }
            return ScheduledSystemEvent(date: date, type: type, owner: entry["scheduledby"] as? String ?? "macOS")
        }.sorted { $0.date < $1.date }
    }

    /// pmset's arbitrary weekday masks print as “Some days”. In that case a
    /// read-only snapshot of its backing plist supplies the mask. Fail closed
    /// if the format changes; never write the preference file ourselves.
    static func parse(_ output: String, backing: [String: Any]? = nil) throws -> [RepeatingPowerSchedule] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == "No scheduled events." ||
                output.contains("Repeating power events:") || output.contains("Scheduled power events:") else {
            throw ScheduleError.invalid("The system schedule format is unrecognised. Editing is disabled to preserve existing events.")
        }
        let pattern = #"^\s*(wakepoweron|wakeorpoweron|poweron|wake|sleep|restart|shutdown) at (\d{1,2}):(\d{2})(AM|PM) (.+?)\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var result: [RepeatingPowerSchedule] = []
        var inRepeating = false
        for line in output.components(separatedBy: .newlines) {
            if line.contains("Repeating power events:") { inRepeating = true; continue }
            if line.contains("Scheduled power events:") || line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { inRepeating = false }
            guard inRepeating, !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                throw ScheduleError.invalid("macOS returned a recurring schedule Squirrel cannot safely edit. Use pmset to inspect it.")
            }
            let ns = line as NSString
            let groups = (1...5).map { ns.substring(with: match.range(at: $0)) }
            let raw = groups[0] == "wakepoweron" ? "wakeorpoweron" : groups[0]
            guard let action = RepeatingPowerSchedule.Action(rawValue: raw), let hour = Int(groups[1]),
                  let minute = Int(groups[2]), (0...12).contains(hour), (0...59).contains(minute) else {
                throw ScheduleError.invalid("The system schedule has an unrecognised time or action.")
            }
            let minutes = (hour % 12 + (groups[3] == "PM" ? 12 : 0)) * 60 + minute
            let masks = ["every day": 127, "weekdays only": 31, "weekends only": 96,
                         "Monday": 1, "Tuesday": 2, "Wednesday": 4, "Thursday": 8, "Friday": 16, "Saturday": 32, "Sunday": 64]
            var days = masks[groups[4]]
            if days == nil {
                let file = URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/com.apple.AutoWake.plist")
                let stored = (try? Data(contentsOf: file)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                let plist = backing ?? stored ?? [:]
                let slot = plist[action.isOn ? "RepeatingPowerOn" : "RepeatingPowerOff"] as? [String: Any]
                let slotType = slot?["eventtype"] as? String
                if slot?["time"] as? Int == minutes, slotType == groups[0] || slotType == raw {
                    days = slot?["weekdays"] as? Int
                }
            }
            guard let days, (1...127).contains(days) else {
                throw ScheduleError.invalid("macOS reports custom weekdays without their exact days. Squirrel could not read the details and has disabled editing to preserve your schedule.")
            }
            result.append(.init(action: action, minutes: minutes, days: days))
        }
        _ = try RepeatingPowerSchedule.arguments(for: result)
        return result
    }

    func apply(_ draft: [RepeatingPowerSchedule], expectedBaseline: String) async -> Bool {
        guard !isApplying, readError == nil else { return false }
        lastError = nil
        do {
            let arguments = try RepeatingPowerSchedule.arguments(for: draft)
            guard try reader(["-g", "sched"]) == expectedBaseline else {
                refresh()
                throw ScheduleError.invalid("The system schedule changed while you were editing. Close and reopen this sheet before applying changes.")
            }
            if draft.filter(\.enabled) != schedules.filter(\.enabled) {
                isApplying = true
                defer { isApplying = false }
                try await writer(arguments, expectedBaseline)
            }
            defaults.set(try JSONEncoder().encode(draft.filter { !$0.enabled }), forKey: Self.draftKey)
            refresh()
            let actual = schedules.filter(\.enabled).sorted { $0.id < $1.id }
            let expected = draft.filter(\.enabled).sorted { $0.id < $1.id }
            guard readError == nil, actual == expected else {
                throw ScheduleError.invalid("macOS did not return the requested schedule. Review the current system settings before trying again.")
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setAutoRestart(_ enabled: Bool) async {
        guard !isApplying else { return }
        lastError = nil
        isApplying = true
        defer { isApplying = false }
        do { try await writer(["-a", "autorestart", enabled ? "1" : "0"], nil) }
        catch { lastError = error.localizedDescription }
    }

    static func pmset(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ScheduleError.invalid(output) }
        return output
    }

    /// Only fixed tokens and validated integers reach pmset. No user text is
    /// interpreted as shell code. macOS owns authorisation and credential UI.
    private static func authorizePMSet(_ arguments: [String], expectedSchedule: String? = nil) async throws {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var command = (["/usr/bin/pmset"] + arguments).map(quote).joined(separator: " ")
        if let expectedSchedule {
            let expected = expectedSchedule.trimmingCharacters(in: .newlines)
            command = "current=$(/usr/bin/pmset -g sched) && if [ \"$current\" = " + quote(expected) + " ]; then " + command + "; else echo 'The system schedule changed during authentication. Reopen the sheet before applying.' >&2; exit 1; fi"
        }
        let script = "do shell script \"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ScheduleError.invalid(String(decoding: data, as: UTF8.self))
            }
        }.value
    }
}
