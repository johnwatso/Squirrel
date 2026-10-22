import XCTest
import SquirrelCore

final class NUTTokenizerTests: XCTestCase {
    func testTokenizesASimpleVariableLine() {
        XCTAssertEqual(
            NUTProtocol.tokenize("VAR ups battery.charge \"100\""),
            ["VAR", "ups", "battery.charge", "100"]
        )
    }

    func testKeepsSpacesInsideAQuotedValue() {
        XCTAssertEqual(
            NUTProtocol.tokenize("UPS ups \"UniFi UPS 2U in the rack\""),
            ["UPS", "ups", "UniFi UPS 2U in the rack"]
        )
    }

    func testUnescapesEmbeddedQuotesAndBackslashes() {
        XCTAssertEqual(
            NUTProtocol.tokenize(#"VAR ups device.model "19\" rack \\ unit""#),
            ["VAR", "ups", "device.model", #"19" rack \ unit"#]
        )
    }

    func testPreservesAnEmptyQuotedValue() {
        XCTAssertEqual(
            NUTProtocol.tokenize("VAR ups ups.alarm \"\""),
            ["VAR", "ups", "ups.alarm", ""]
        )
    }

    func testCollapsesRunsOfWhitespaceBetweenTokens() {
        XCTAssertEqual(NUTProtocol.tokenize("CMD   ups\ttest.battery.start"),
                       ["CMD", "ups", "test.battery.start"])
    }

    func testQuotingEscapesQuotesAndBackslashes() {
        XCTAssertEqual(NUTProtocol.quote(#"say "hi"\"#), #""say \"hi\"\\""#)
    }

    func testCommandQuotesOnlyTheFinalArgumentWhenAsked() {
        XCTAssertEqual(
            NUTProtocol.command("SET", ["VAR", "ups", "ups.id", "rack one"], quotingLast: true),
            #"SET VAR ups ups.id "rack one""#
        )
        XCTAssertEqual(NUTProtocol.command("LIST", ["VAR", "ups"]), "LIST VAR ups")
    }
}

final class NUTErrorTests: XCTestCase {
    func testMapsKnownErrorTokens() {
        XCTAssertEqual(NUTError(errorLine: "ERR ACCESS-DENIED"), .accessDenied)
        XCTAssertEqual(NUTError(errorLine: "ERR UNKNOWN-UPS"), .unknownUPS)
        XCTAssertEqual(NUTError(errorLine: "ERR DATA-STALE"), .dataStale)
        XCTAssertEqual(NUTError(errorLine: "ERR DRIVER-NOT-CONNECTED"), .driverNotConnected)
        XCTAssertEqual(NUTError(errorLine: "ERR VAR-NOT-SUPPORTED"), .variableNotSupported)
    }

    func testKeepsAnUnrecognisedTokenRatherThanDiscardingIt() {
        XCTAssertEqual(NUTError(errorLine: "ERR SOME-FUTURE-TOKEN"), .server("SOME-FUTURE-TOKEN"))
    }

    func testNonErrorLinesAreNotErrors() {
        XCTAssertNil(NUTError(errorLine: "OK"))
        XCTAssertNil(NUTError(errorLine: "VAR ups battery.charge \"100\""))
    }

    /// The cases that must stop a stale reading being presented to powerd as
    /// the truth about the Mac's power.
    func testOnlyTrustDestroyingErrorsInvalidateAReading() {
        XCTAssertTrue(NUTError.dataStale.invalidatesReading)
        XCTAssertTrue(NUTError.driverNotConnected.invalidatesReading)
        XCTAssertTrue(NUTError.notConnected.invalidatesReading)
        XCTAssertTrue(NUTError.timedOut.invalidatesReading)
        XCTAssertFalse(NUTError.commandNotSupported.invalidatesReading)
        XCTAssertFalse(NUTError.readOnly.invalidatesReading)
    }
}
