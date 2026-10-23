import XCTest
import SquirrelCore
@testable import Squirrel

final class UPSNamingTests: XCTestCase {
    private func name(_ variables: [String: String]) -> String? {
        UPSNaming.suggestedName(for: UPSReading(upsName: "ups", variables: variables))
    }

    /// The case that started this: the UniFi UPS 2U reports its SKU.
    func testUniFiSKUsBecomeTheProductName() {
        XCTAssertEqual(name(["ups.mfr": "Ubiquiti", "ups.model": "2U_1500VA_230V", "ups.power.nominal": "1500"]), "UniFi UPS 2U")
        XCTAssertEqual(name(["ups.mfr": "Ubiquiti", "ups.model": "2U_1500VA_120V"]), "UniFi UPS 2U")
        XCTAssertEqual(name(["ups.mfr": "Ubiquiti", "ups.model": "XY_2000VA_230V"]), "UniFi UPS")
    }

    func testReadableModelsGainTheirMaker() {
        XCTAssertEqual(name(["device.mfr": "American Power Conversion", "device.model": "Back-UPS XS 1500G"]), "APC Back-UPS XS 1500G")
        XCTAssertEqual(name(["ups.mfr": "CPS", "ups.model": "CP1500PFCLCD"]), "CyberPower CP1500PFCLCD")
    }

    func testAMakerAlreadyInTheModelIsNotDoubled() {
        XCTAssertEqual(name(["ups.mfr": "EATON", "ups.model": "Eaton 5E 1500i"]), "Eaton 5E 1500i")
    }

    func testFirmwareSuffixesAreDropped() {
        XCTAssertEqual(name(["ups.mfr": "APC", "ups.model": "Back-UPS CS 650 FW:817.v9.I USB FW:v9"]), "APC Back-UPS CS 650")
    }

    func testAPCSmartUPSUnderscoresAreTidied() {
        XCTAssertEqual(name(["ups.mfr": "American Power Conversion", "ups.model": "Smart-UPS_1500"]), "APC Smart-UPS 1500")
    }

    func testUnknownCodeLikeModelsFallBackToMakerAndSize() {
        XCTAssertEqual(name(["ups.mfr": "ACME POWER CO., LTD", "ups.model": "AB_12_X", "ups.power.nominal": "1000"]), "Acme Power 1000 VA UPS")
    }

    /// "Generic" and "Unknown" are what drivers say when they know nothing.
    func testMeaninglessValuesAreIgnored() {
        XCTAssertNil(name(["ups.mfr": "Generic", "ups.model": "Unknown"]))
        XCTAssertEqual(name(["ups.mfr": "Unknown", "ups.model": "Back-UPS ES 700G"]), "Back-UPS ES 700G")
        XCTAssertNil(name([:]))
    }

    func testOnlyRawNamesAreOfferedARename() {
        let device = UPSDevice(displayName: "2U_1500VA_230V", host: "10.0.0.2", upsName: "10.0.0.2")
        let reading = UPSReading(upsName: "10.0.0.2", variables: ["ups.model": "2U_1500VA_230V"])
        XCTAssertTrue(UPSNaming.isRawName(device.displayName, for: device, reading: reading))
        XCTAssertTrue(UPSNaming.isRawName("10.0.0.2", for: device, reading: nil))
        XCTAssertFalse(UPSNaming.isRawName("Network Rack UPS", for: device, reading: reading))
    }
}

final class NUTServerKindTests: XCTestCase {
    func testRecognisesEachServerFromItsOwnClues() {
        XCTAssertEqual(NUTServerKind.detect(hostName: "DiskStation"), .synology)
        XCTAssertEqual(NUTServerKind.detect(hostName: nil, upsNames: ["qnapups"]), .qnap)
        XCTAssertEqual(NUTServerKind.detect(hostName: nil, manufacturers: ["Ubiquiti"]), .unifi)
    }

    /// "ups" is NUT's own default name; a Raspberry Pi uses it as often as a
    /// Synology does, so it proves nothing on its own.
    func testTheDefaultUPSNameAloneIsNotASynology() {
        XCTAssertNil(NUTServerKind.detect(hostName: "pi", upsNames: ["ups"]))
    }

    func testInstructionsNameThisMacsAddress() {
        XCTAssertTrue(NUTServerKind.synology.accessInstructions(macAddress: "10.11.1.20").contains("10.11.1.20"))
        XCTAssertTrue(NUTServerKind.synology.accessInstructions(macAddress: "10.11.1.20").contains("Permitted DiskStation Devices"))
    }

    func testNASDefaultsAreTheFixedOnes() {
        XCTAssertEqual(NUTServerKind.synology.defaultCredentials?.username, "monuser")
        XCTAssertEqual(NUTServerKind.qnap.defaultCredentials?.username, "admin")
        XCTAssertNil(NUTServerKind.unifi.defaultCredentials)
    }

    func testAddressDoesNotRepeatAUPSNamedAfterItsServer() {
        XCTAssertEqual(UPSNaming.address(upsName: "ups", host: "10.0.0.4"), "ups@10.0.0.4")
        XCTAssertEqual(UPSNaming.address(upsName: "10.11.1.46", host: "10.11.1.46"), "10.11.1.46")
        XCTAssertEqual(UPSNaming.address(upsName: "10.11.1.46", host: "10.11.1.46", hostName: "ups2u.localdomain"), "ups2u.localdomain · 10.11.1.46")
        XCTAssertEqual(UPSNaming.address(upsName: "UPS2U.localdomain", host: "10.11.1.46", hostName: "ups2u.localdomain"), "ups2u.localdomain · 10.11.1.46")
    }
}
