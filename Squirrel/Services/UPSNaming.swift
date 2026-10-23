import Foundation
import SquirrelCore

/// Turns what a UPS reports about itself into a name a person would use.
///
/// UPSes report a manufacturer and model, but in whatever form their firmware
/// or NUT driver chose: "American Power Conversion" and "APC" are the same
/// company, and Ubiquiti's "2U_1500VA_230V" is the product sold as the UniFi
/// UPS 2U. This is a starting suggestion only — the user can always rename —
/// so it prefers a plain, honest name over a clever wrong one.
enum UPSNaming {
    /// The best name for a new UPS, or nil when nothing it reports is usable.
    static func suggestedName(for reading: UPSReading?) -> String? {
        guard let reading else { return nil }
        let maker = manufacturer(in: reading)
        let model = cleanedModel(reading.model)

        if let maker, let model, let known = knownProduct(maker: maker, model: model) {
            return known
        }

        switch (maker, model) {
        case let (maker?, model?):
            if isCodeLike(model) {
                return sizedName(maker: maker, reading: reading) ?? "\(maker) \(readable(model))"
            }
            // "Eaton 5E 1500i", without doubling a maker the model already names.
            return model.lowercased().hasPrefix(maker.lowercased()) ? model : "\(maker) \(model)"
        case let (maker?, nil):
            return sizedName(maker: maker, reading: reading) ?? "\(maker) UPS"
        case let (nil, model?):
            return isCodeLike(model) ? readable(model) : model
        case (nil, nil):
            return nil
        }
    }

    /// Whether a configured name is just what the hardware calls itself, and
    /// so worth offering a friendlier one for. Never true for a name the user
    /// typed.
    static func isRawName(_ name: String, for device: UPSDevice, reading: UPSReading?) -> Bool {
        if name == device.upsName { return true }
        guard let reading else { return false }
        return name == reading.model || name == reading.value("device.model") || name == reading.value("ups.model")
    }

    // MARK: - Manufacturer

    /// The maker as people know it, from whichever of `device.mfr` or
    /// `ups.mfr` this UPS reports.
    static func manufacturer(in reading: UPSReading) -> String? {
        guard let raw = reading.value("device.mfr") ?? reading.value("ups.mfr") else { return nil }
        return normalisedManufacturer(raw)
    }

    static func normalisedManufacturer(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        guard !key.isEmpty, !meaninglessValues.contains(key) else { return nil }

        for (prefixes, name) in manufacturerAliases where prefixes.contains(where: { key.hasPrefix($0) }) {
            return name
        }

        // An unknown maker: drop the corporate suffix and the shouting.
        var name = trimmed
        for suffix in corporateSuffixes {
            if name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
            }
        }
        if name.count > 4, name == name.uppercased(), name.rangeOfCharacter(from: .lowercaseLetters) == nil {
            name = name.capitalized
        }
        return name.isEmpty ? nil : name
    }

    /// Matched against the start of the lowercased manufacturer string.
    private static let manufacturerAliases: [([String], String)] = [
        (["american power conversion", "apc", "schneider"], "APC"),
        (["cyber power", "cyberpower", "cps"], "CyberPower"),
        (["eaton", "mge"], "Eaton"),
        (["tripp lite", "tripp-lite", "trippe", "tripplite"], "Tripp Lite"),
        (["ubiquiti", "ubnt"], "Ubiquiti"),
        (["powerwalker"], "PowerWalker"),
        (["bluewalker"], "BlueWalker"),
        (["powercom"], "Powercom"),
        (["riello"], "Riello"),
        (["vertiv", "liebert", "emerson"], "Vertiv"),
        (["salicru"], "Salicru"),
        (["socomec"], "Socomec"),
        (["delta"], "Delta"),
        (["legrand"], "Legrand"),
        (["huawei"], "Huawei"),
        (["fsp"], "FSP"),
        (["green cell"], "Green Cell"),
        (["ablerex"], "Ablerex"),
        (["infosec"], "Infosec"),
        (["orvaldi"], "Orvaldi"),
    ]

    private static let corporateSuffixes = [
        " co., ltd", " co.,ltd", " co. ltd", " co ltd", " ltd.", " ltd", " inc.", " inc",
        " corporation", " corp.", " corp", " gmbh", " s.p.a.", " s.a.", " limited",
    ]

    /// Values drivers report when they know nothing. A UPS "made by Generic"
    /// is not a name.
    private static let meaninglessValues: Set<String> = [
        "unknown", "generic", "ups", "unavailable", "n/a", "na", "none", "default", "0", "-",
    ]

    // MARK: - Model

    /// The model with the noise taken off: firmware suffixes some APC units
    /// append, and runs of whitespace.
    static func cleanedModel(_ raw: String?) -> String? {
        guard var model = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        if let firmware = model.range(of: " FW:") {
            model = String(model[..<firmware.lowerBound])
        }
        model = model.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !meaninglessValues.contains(model.lowercased()), model.count <= 48,
              model.rangeOfCharacter(from: .letters) != nil else { return nil }
        return model
    }

    /// A SKU rather than a product name: underscores and no spaces, like
    /// "2U_1500VA_230V". "CP1500PFCLCD" is terse but is what it says on the
    /// box, so it is not treated as code.
    static func isCodeLike(_ model: String) -> Bool {
        model.contains("_") && !model.contains(" ")
    }

    /// Underscores to spaces, so "Smart-UPS_1500" reads as "Smart-UPS 1500".
    private static func readable(_ model: String) -> String {
        model.replacingOccurrences(of: "_", with: " ")
    }

    /// "Ubiquiti 1500 VA UPS", from the nominal rating, when the model itself
    /// says nothing useful.
    private static func sizedName(maker: String, reading: UPSReading) -> String? {
        if let va = reading.number("ups.power.nominal"), va > 0 {
            return "\(maker) \(Int(va)) VA UPS"
        }
        if let watts = reading.number("ups.realpower.nominal"), watts > 0 {
            return "\(maker) \(Int(watts)) W UPS"
        }
        return nil
    }

    /// Where a UPS lives, for a detail line: NUT's own "ups@host", except
    /// when the server names its UPS after itself (a UniFi UPS serves one
    /// called by its own address), where that would only say the address twice.
    static func address(upsName: String, host: String, hostName: String? = nil) -> String {
        let name = upsName.lowercased()
        guard name == host.lowercased() || name == hostName?.lowercased() else { return "\(upsName)@\(host)" }
        return [hostName, host].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Known products

    /// Products whose reported model is a code that only a table can map to
    /// the name on the box. Kept deliberately small: only entries whose
    /// reported strings are known, matched on the maker and a model pattern.
    private static let knownProducts: [(maker: String, matches: @Sendable (String) -> Bool, name: String)] = [
        // UniFi UPSes run their own NUT server and report the SKU, e.g.
        // "2U_1500VA_230V" or "2U_1500VA_120V".
        ("Ubiquiti", { $0.uppercased().hasPrefix("2U_") || $0.uppercased().hasPrefix("UPS-2U") }, "UniFi UPS 2U"),
        ("Ubiquiti", { $0.lowercased().contains("tower") }, "UniFi UPS Tower"),
        // Ubiquiti's only UPSes are UniFi ones; a model we have not seen yet
        // is still better called that than by its SKU.
        ("Ubiquiti", { isCodeLike($0) }, "UniFi UPS"),
        // APC's newer Smart-UPS report "Smart-UPS_1500"; the underscore is the
        // only thing wrong with it.
        ("APC", { $0.hasPrefix("Smart-UPS_") }, ""),
    ]

    static func knownProduct(maker: String, model: String) -> String? {
        guard let entry = knownProducts.first(where: { $0.maker == maker && $0.matches(model) }) else { return nil }
        return entry.name.isEmpty ? "\(maker) \(readable(model))" : entry.name
    }
}
