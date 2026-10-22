import XCTest
@testable import Squirrel

final class PowerProfileAdvisorTests: XCTestCase {
    /// Real `pmset -g custom` output from a Mac mini, which is the machine
    /// class this whole feature targets. Note the UPS profile's one-minute
    /// idle sleep: that is the trap this advisor exists to catch.
    private let sample = """
    UPS Power:
     Sleep On Power Button 1
     autorestartatconnect 0
     standby              0
     powernap             1
     ttyskeepawake        1
     womp                 0
     displaysleep         2
     networkoversleep     0
     sleep                1
     autorestart          0
     tcpkeepalive         1
     disksleep            10
    AC Power:
     Sleep On Power Button 1
     autorestartatconnect 0
     standby              0
     ttyskeepawake        1
     powernap             1
     womp                 1
     displaysleep         0
     networkoversleep     0
     sleep                0
     tcpkeepalive         1
     autorestart          1
     disksleep            10
    """

    func testReadsTheUPSProfileRatherThanTheACProfile() {
        let advice = PowerProfileAdvisor.parse(pmsetCustomOutput: sample)
        XCTAssertEqual(advice.sleepMinutes, 1)
        XCTAssertEqual(advice.displaySleepMinutes, 2)
    }

    func testFlagsAMacThatWouldSleepStraightThroughAnOutage() {
        XCTAssertTrue(PowerProfileAdvisor.parse(pmsetCustomOutput: sample).sleepsTooSoon)
    }

    func testNeverSleepingIsNotAProblem() {
        let output = "UPS Power:\n sleep                0\n displaysleep         0\n"
        let advice = PowerProfileAdvisor.parse(pmsetCustomOutput: output)
        XCTAssertEqual(advice.sleepMinutes, 0)
        XCTAssertFalse(advice.sleepsTooSoon)
    }

    func testAComfortableSleepTimerIsNotFlagged() {
        let output = "UPS Power:\n sleep                45\n"
        XCTAssertFalse(PowerProfileAdvisor.parse(pmsetCustomOutput: output).sleepsTooSoon)
    }

    /// "Sleep On Power Button 1" must not be mistaken for the sleep timer.
    func testDoesNotConfuseOtherSettingsWithTheSleepTimer() {
        let output = "UPS Power:\n Sleep On Power Button 1\n disksleep            10\n"
        let advice = PowerProfileAdvisor.parse(pmsetCustomOutput: output)
        XCTAssertNil(advice.sleepMinutes)
        XCTAssertFalse(advice.sleepsTooSoon)
    }

    func testEmptyOutputYieldsNoAdvice() {
        let advice = PowerProfileAdvisor.parse(pmsetCustomOutput: "")
        XCTAssertNil(advice.sleepMinutes)
        XCTAssertNil(advice.displaySleepMinutes)
    }

    /// The restart that matters is the AC profile's: it applies when mains
    /// returns, and the UPS profile's copy (0 in this sample) does not.
    func testReadsAutomaticRestartFromTheACProfile() {
        XCTAssertEqual(PowerProfileAdvisor.parse(pmsetCustomOutput: sample).autoRestartEnabled, true)
    }

    func testAutomaticRestartSupportComesFromCapabilities() {
        XCTAssertEqual(PowerProfileAdvisor.supportsAutoRestart(pmsetCapOutput: "Capabilities for AC Power:\n displaysleep\n autorestart\n"), true)
        XCTAssertEqual(PowerProfileAdvisor.supportsAutoRestart(pmsetCapOutput: "Capabilities for AC Power:\n displaysleep\n autorestartatconnect\n"), false)
        XCTAssertNil(PowerProfileAdvisor.supportsAutoRestart(pmsetCapOutput: ""))
    }
}
