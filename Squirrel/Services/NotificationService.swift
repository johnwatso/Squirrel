import AppKit
import Foundation
import SquirrelCore
import UserNotifications
import os

/// Tells the user when the power situation changes.
///
/// One notification per change, never per poll: the monitor reads the UPS
/// every few seconds, and an outage that lasted an hour should not produce
/// hundreds of banners.
@MainActor
final class NotificationService: ObservableObject {
    /// The states worth telling someone about. Transitions between these are
    /// what trigger a notification, not the readings themselves.
    enum Condition: Equatable {
        case normal
        case onBattery
        case lowBattery
        /// The NUT server answers, but has lost contact with the UPS itself.
        case upsUnavailable
        /// The NUT server cannot be reached at all.
        case serverUnavailable

        var isConnectionProblem: Bool {
            self == .upsUnavailable || self == .serverUnavailable
        }
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let settings: SettingsStore
    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "Notifications")

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var statusDescription: String {
        switch authorizationStatus {
        case .notDetermined: return "Not requested yet"
        case .denied: return "Turned off in System Settings"
        case .authorized: return "Allowed"
        case .provisional: return "Delivered quietly"
        case .ephemeral: return "Allowed temporarily"
        @unknown default: return "Unknown"
        }
    }

    var isDenied: Bool { authorizationStatus == .denied }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Asks macOS, but only when it has not already answered.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        await refreshAuthorizationStatus()
    }

    static func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Events

    /// Posts a notification for a change the monitor has already decided is
    /// real. Which changes are worth a banner is the user's call, made per
    /// kind in Settings; the master switch silences them all.
    func notify(from previous: Condition, to condition: Condition, for device: UPSDevice, reading: UPSReading?) {
        let prefs = settings.preferences
        guard prefs.showNotifications else { return }
        switch (previous, condition) {
        case (_, .lowBattery):
            guard prefs.notifyLowBattery else { return }
        case (_, .upsUnavailable), (_, .serverUnavailable):
            guard prefs.notifyConnectionProblems else { return }
        case (.upsUnavailable, .normal), (.serverUnavailable, .normal):
            guard prefs.notifyConnectionProblems else { return }
        default:
            guard prefs.notifyPowerChanges else { return }
        }
        guard let message = Self.message(from: previous, to: condition, reading: reading, device: device) else { return }
        post(title: device.displayName, body: message)
    }

    private static func message(from previous: Condition, to condition: Condition, reading: UPSReading?, device: UPSDevice) -> String? {
        let detail = detail(for: reading)
        switch condition {
        case .onBattery:
            return "Running on battery.\(detail)"
        case .lowBattery:
            // "Low battery" and "Forced shutdown initiated" are different
            // messages; let the UPS's own status say which one this is.
            let headline = reading.map { UPSStatusPresentation.headline(for: $0.status) } ?? "Battery is low"
            return "\(headline).\(detail) Your Mac will shut down if mains power doesn't return."
        case .normal:
            switch previous {
            case .upsUnavailable, .serverUnavailable: return "Squirrel is reading this UPS again.\(detail)"
            case .onBattery, .lowBattery: return "Mains power is back.\(detail)"
            case .normal: return nil
            }
        case .upsUnavailable:
            return "The NUT server has lost contact with this UPS.\(presenceNote(device))"
        case .serverUnavailable:
            return "Squirrel can't reach the NUT server at \(device.host).\(presenceNote(device))"
        }
    }

    private static func presenceNote(_ device: UPSDevice) -> String {
        device.publishesToSystem ? " macOS has been told the UPS isn't present." : ""
    }

    private static func detail(for reading: UPSReading?) -> String {
        guard let reading else { return "" }
        var parts: [String] = []
        if let charge = reading.batteryCharge { parts.append("\(charge)%") }
        if let runtime = reading.batteryRuntime, reading.status.isRunningOnBattery {
            parts.append("\(UPSTelemetry.duration(seconds: runtime)) left")
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " · ") + "."
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { [log] error in
            if let error {
                log.error("Could not post a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
