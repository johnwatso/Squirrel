import Foundation
import IOKit.pwr_mgt
import os

/// Keeps the Mac awake for the duration of an outage.
///
/// macOS applies its UPS Power settings profile the moment a UPS power source
/// goes onto battery, and that profile commonly sleeps the machine within a
/// couple of minutes. A sleeping Mac may never reach its own shutdown
/// threshold, so Squirrel holds the system awake until line power returns.
@MainActor
final class SleepAssertionService: ObservableObject {
    @Published private(set) var isHoldingAssertion = false

    private let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "SleepAssertion")
    private var assertionID: IOPMAssertionID = 0

    func beginHoldingAwake(reason: String) {
        guard !isHoldingAssertion else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard status == kIOReturnSuccess else {
            log.error("Could not hold the Mac awake: \(status)")
            return
        }
        assertionID = id
        isHoldingAssertion = true
        log.notice("Holding the Mac awake for the duration of the outage")
    }

    func endHoldingAwake() {
        guard isHoldingAssertion else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHoldingAssertion = false
        log.notice("Released the wake assertion")
    }
}
