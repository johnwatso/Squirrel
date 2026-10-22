import Foundation

/// NUT servers that ship inside other products, each with its own fixed
/// defaults and its own way of turning a Mac away.
///
/// Recognised from what the server itself reports, never assumed: plenty of
/// Raspberry Pis also serve a UPS called "ups", so that name alone proves
/// nothing.
enum NUTServerKind: String, CaseIterable, Identifiable, Sendable {
    case synology
    case qnap
    case unifi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .synology: return "Synology NAS"
        case .qnap: return "QNAP NAS"
        case .unifi: return "UniFi UPS"
        }
    }

    /// The credentials the product uses for its network UPS server. Synology
    /// and QNAP fix these and do not let you change them.
    var defaultCredentials: (username: String, password: String)? {
        switch self {
        case .synology: return ("monuser", "secret")
        case .qnap: return ("admin", "123456")
        case .unifi: return nil
        }
    }

    /// What the user has to do on the server so that it will talk to this
    /// Mac, in that product's own words.
    func accessInstructions(macAddress: String?) -> String {
        let mac = macAddress.map { "this Mac's address, \($0)" } ?? "this Mac's IP address"
        switch self {
        case .synology:
            return "In DSM, open Control Panel → Hardware & Power → UPS, turn on “Enable network UPS server”, then click Permitted DiskStation Devices and add \(mac)."
        case .qnap:
            return "In QTS, open Control Panel → System → External Device → UPS, turn on “Enable network UPS master”, and add \(mac) to the IP addresses allowed to connect."
        case .unifi:
            return "In UniFi, check that this UPS's network UPS (NUT) server is turned on and that \(mac) is allowed to connect."
        }
    }

    /// When the kind of server is unknown, the two common NAS fixes together.
    static func genericAccessInstructions(macAddress: String?) -> String {
        let mac = macAddress.map { "this Mac's address, \($0)" } ?? "this Mac's IP address"
        return "Check that network UPS (NUT) sharing is turned on for the server. Many servers also only answer devices on a permitted list. On a Synology NAS that's Control Panel → Hardware & Power → UPS → Permitted DiskStation Devices; on a QNAP NAS, the allowed IP list under Control Panel → System → External Device → UPS. Add \(mac)."
    }

    /// Recognises the server from what it reported. Any one clue is enough,
    /// but each clue is specific to its product.
    static func detect(
        hostName: String?,
        upsNames: [String] = [],
        descriptions: [String] = [],
        manufacturers: [String] = []
    ) -> NUTServerKind? {
        let host = hostName?.lowercased() ?? ""
        let text = descriptions.joined(separator: " ").lowercased()

        if manufacturers.contains("Ubiquiti") {
            return .unifi
        }
        if upsNames.contains("qnapups") || host.contains("qnap") || text.contains("qnap") {
            return .qnap
        }
        let synologyHosts = ["diskstation", "rackstation", "flashstation", "synology"]
        if synologyHosts.contains(where: host.contains) || text.contains("synology") {
            return .synology
        }
        return nil
    }
}
