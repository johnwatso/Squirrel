import Foundation
import IOKit.ps

/// Reads back what macOS currently believes about power sources.
///
/// Two uses: proving to the user that Squirrel's integration is live, and
/// noticing a real USB UPS so we do not publish a duplicate alongside it.
public enum SystemPowerSources {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let type: String
        public let transportType: String
        public let isPresent: Bool
        public let currentCapacity: Int?
        public let state: String?

        public init(name: String, type: String, transportType: String, isPresent: Bool, currentCapacity: Int?, state: String?) {
            self.name = name
            self.type = type
            self.transportType = transportType
            self.isPresent = isPresent
            self.currentCapacity = currentCapacity
            self.state = state
        }

        public var isUPS: Bool { type == PSValue.upsType }
        public var isNetworkTransport: Bool { transportType == PSValue.networkType }
    }

    /// Every power source macOS knows about, Squirrel's own included.
    public static func current() -> [Entry] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }

        return sources.compactMap { source in
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { return nil }
            return Entry(
                name: description[PSKey.name] as? String ?? "Unknown",
                type: description[PSKey.type] as? String ?? "",
                transportType: description[PSKey.transportType] as? String ?? "",
                isPresent: description[PSKey.isPresent] as? Bool ?? false,
                currentCapacity: description[PSKey.currentCapacity] as? Int,
                state: description[PSKey.state] as? String
            )
        }
    }

    /// Whether macOS is right now reporting the UPS Squirrel published under
    /// this name.
    ///
    /// The honest answer to "did the native integration work?": the name and
    /// the network transport together identify our own power source, and
    /// `isPresent` is what separates a live UPS from the placeholder published
    /// when a reading has gone stale.
    public static func publishedUPS(named name: String) -> Entry? {
        current().first { $0.isUPS && $0.isNetworkTransport && $0.name == name && $0.isPresent }
    }

    public static func isPublishedUPSVisible(named name: String) -> Bool {
        publishedUPS(named: name) != nil
    }

    /// A UPS macOS already knows about that Squirrel did not publish — almost
    /// always a real one on USB.
    public static func foreignUPS(excludingName name: String?) -> Entry? {
        current().first { $0.isUPS && $0.name != name }
    }
}
