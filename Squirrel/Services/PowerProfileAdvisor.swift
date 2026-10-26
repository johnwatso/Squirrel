import Foundation

/// Reads the UPS Power settings profile and flags the configuration that
/// quietly defeats UPS shutdown: a Mac that sleeps a minute into an outage can
/// never reach its own halt threshold.
///
/// A USB UPS owner never thinks about this. Neither should ours — so Squirrel
/// surfaces it instead of leaving the user to find Energy Saver.
struct PowerProfileAdvisor {
    struct Advice: Equatable, Sendable {
        /// Idle sleep timer on UPS power, in minutes. 0 means never.
        var sleepMinutes: Int?
        var displaySleepMinutes: Int?

        /// macOS's own emergency shutdown thresholds, as `pmset -g ups`
        /// reports them. Nil means the threshold is switched off; a value of
        /// nil for all three with `didReadThresholds` false means pmset could
        /// not be read, which is not the same as "none are set".
        var haltLevelPercent: Int?
        var haltAfterMinutes: Int?
        var haltRemainMinutes: Int?
        var didReadThresholds = false

        /// macOS's "Start up automatically after a power failure". A setting of
        /// the Mac, not the UPS: nil when this Mac does not offer it, or when
        /// pmset could not say.
        var autoRestartSupported: Bool?
        var autoRestartEnabled: Bool?

        /// True when the Mac would sleep soon enough that a shutdown threshold
        /// might never fire. On its own this is a fact about the user's
        /// configuration, not a problem.
        var sleepsTooSoon: Bool {
            guard let sleepMinutes, sleepMinutes > 0 else { return false }
            return sleepMinutes <= 5
        }

        var hasShutdownThreshold: Bool {
            haltLevelPercent != nil || haltAfterMinutes != nil || haltRemainMinutes != nil
        }

        /// Whether there is something here the user should actually act on.
        ///
        /// A short sleep timer only matters when macOS has a shutdown
        /// threshold it would never reach, and Squirrel is not already holding
        /// the Mac awake through the outage. Otherwise it is just how they
        /// have set their Mac up, and saying so in a warning is noise.
        func needsAttention(whenKeepingAwake keepsAwake: Bool) -> Bool {
            guard didReadThresholds else { return false }
            return sleepsTooSoon && hasShutdownThreshold && !keepsAwake
        }
    }

    var runner: @Sendable ([String]) -> String? = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Not waitUntilExit: it spins the caller's run loop, and on the main
        // thread during a window update that re-enters AppKit and crashes.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return String(data: data, encoding: .utf8)
    }

    func currentAdvice() -> Advice {
        guard let output = runner(["-g", "custom"]) else { return Advice() }
        var advice = Self.parse(pmsetCustomOutput: output)
        // Read, never guessed: if pmset will not answer, the thresholds stay
        // unknown rather than being reported as switched off.
        if let thresholds = runner(["-g", "ups"]) {
            Self.apply(pmsetUPSOutput: thresholds, to: &advice)
        }
        if let capabilities = runner(["-g", "cap"]) {
            advice.autoRestartSupported = Self.supportsAutoRestart(pmsetCapOutput: capabilities)
        }
        if advice.autoRestartSupported == false {
            advice.autoRestartEnabled = nil
        }
        return advice
    }

    /// Pulls the emergency shutdown thresholds out of `pmset -g ups`, whose
    /// lines read `haltlevel<tab>on<tab>25`.
    static func apply(pmsetUPSOutput output: String, to advice: inout Advice) {
        var sawAnySetting = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3 else { continue }
            let enabled = fields[1].lowercased() == "on"
            guard let value = Int(fields[2]) else { continue }
            let setting = enabled ? value : nil
            switch fields[0] {
            case "haltlevel":  advice.haltLevelPercent = setting; sawAnySetting = true
            case "haltafter":  advice.haltAfterMinutes = setting; sawAnySetting = true
            case "haltremain": advice.haltRemainMinutes = setting; sawAnySetting = true
            default: continue
            }
        }
        advice.didReadThresholds = sawAnySetting
    }

    static func parse(pmsetUPSOutput output: String) -> Advice {
        var advice = Advice()
        apply(pmsetUPSOutput: output, to: &advice)
        return advice
    }

    /// `pmset -g cap` lists, per power source, the settings this Mac has. A
    /// Mac without `autorestart` there cannot start itself after an outage.
    static func supportsAutoRestart(pmsetCapOutput output: String) -> Bool? {
        let tokens = output.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }
        return tokens.contains("autorestart")
    }

    /// Pulls the UPS Power block out of `pmset -g custom`, and the AC Power
    /// block's restart setting: it is what applies when mains comes back.
    static func parse(pmsetCustomOutput output: String) -> Advice {
        var advice = Advice()
        var inUPSBlock = false
        var inACBlock = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasSuffix("Power:") {
                inUPSBlock = trimmed.hasPrefix("UPS")
                inACBlock = trimmed.hasPrefix("AC")
                continue
            }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let value = Int(fields[fields.count - 1]) else { continue }

            if inACBlock, fields[0] == "autorestart" {
                advice.autoRestartEnabled = value != 0
                continue
            }
            guard inUPSBlock else { continue }
            switch fields[0] {
            case "sleep": advice.sleepMinutes = value
            case "displaysleep": advice.displaySleepMinutes = value
            default: break
            }
        }
        return advice
    }
}
