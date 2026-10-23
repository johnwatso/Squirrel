import Foundation
import SquirrelCore

/// A configured UPS: which NUT server to ask, and which UPS on it.
struct UPSDevice: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var host: String
    var port: UInt16
    /// The name upsd serves this UPS under. Discovered with `LIST UPS`, never
    /// typed by the user — guessing it is the single most common setup failure.
    var upsName: String
    var username: String?
    /// Whether this UPS is the one presented to macOS as *the* UPS. Only one
    /// can be, because the Mac has one set of shutdown thresholds.
    var publishesToSystem: Bool
    var pollInterval: TimeInterval
    /// The drawing the user picked when Squirrel guessed wrong, as a
    /// `UPSIllustrationKind` raw value; nil means detect it from the reading.
    /// Kept as text so a drawing a later version drops can never stop the
    /// device list from loading.
    var illustrationOverride: String? = nil

    init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: UInt16 = 3493,
        upsName: String,
        username: String? = nil,
        publishesToSystem: Bool = true,
        pollInterval: TimeInterval = 5
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.upsName = upsName
        self.username = username
        self.publishesToSystem = publishesToSystem
        self.pollInterval = pollInterval
    }

    var keychainAccount: String { "\(host):\(port)/\(upsName)" }

    func clientConfiguration(password: String?) -> NUTClient.Configuration {
        NUTClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password
        )
    }
}

/// What the menu bar shows for a UPS right now.
enum UPSConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case online(UPSReading)
    case failed(String)

    var reading: UPSReading? {
        if case .online(let reading) = self { return reading }
        return nil
    }
}
