import XCTest
@testable import Squirrel
import SquirrelCore

final class UPSIllustrationTests: XCTestCase {
    func testUniFiModelsPickTheirOwnDrawings() {
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Ubiquiti", model: "2U_1500VA_230V"), .unifiRack)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Ubiquiti", model: "UPS-Tower"), .unifiTower)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Ubiquiti", model: nil), .unifiRack)
    }

    func testPopularTowersPickTheirMakersDrawing() {
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "APC", model: "Back-UPS RS 1500G"), .apcBackUPS)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "APC", model: "Back-UPS XS 1500G"), .apcBackUPS)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "APC", model: "Smart-UPS 1500"), .apcSmartUPS)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "APC", model: "SMT1500IC"), .apcSmartUPS)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "CyberPower", model: "CP1500PFCLCD"), .cyberPowerTower)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Eaton", model: "5SC1500I"), .eatonTower)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Eaton", model: "5E 1500i"), .eatonTower)
    }

    func testRackModelCodesPickARackDrawing() {
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "APC", model: "SMT1500RMI2U"), .lcdRack)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "APC", model: "Smart-UPS 1500 RM"), .lcdRack)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "CyberPower", model: "OR1500LCDRM1U"), .lcdRack)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "CyberPower", model: "PR1500ELCDRT2U"), .lcdRack)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Eaton", model: "5PX1500IRT"), .lcdRack)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Eaton", model: "5SC1500IR"), .lcdRack)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Tripp Lite", model: "SMART1500RM2U"), .lcdRack)
    }

    func testAChosenPictureWinsOverDetection() {
        let reading = UPSReading(upsName: "ups", variables: ["ups.mfr": "CyberPower", "ups.model": "CP1500PFCLCD"])
        var device = UPSDevice(displayName: "Desk", host: "10.0.0.2", upsName: "ups")
        XCTAssertEqual(device.illustration(for: reading), .cyberPowerTower)
        device.illustrationOverride = UPSIllustrationKind.genericRack.rawValue
        XCTAssertEqual(device.illustration(for: reading), .genericRack)
        // A drawing a later version no longer has falls back to detection.
        device.illustrationOverride = "retiredDrawing"
        XCTAssertEqual(device.illustration(for: reading), .cyberPowerTower)
    }

    func testDevicesSavedBeforePicturesStillLoad() throws {
        let saved = #"{"id":"6F1B9C7E-1C55-4C38-9E8E-2B7B4C1D0A11","displayName":"Rack","host":"10.0.0.2","port":3493,"upsName":"ups","publishesToSystem":true,"pollInterval":5}"#
        let device = try JSONDecoder().decode(UPSDevice.self, from: Data(saved.utf8))
        XCTAssertNil(device.illustrationOverride)
    }

    func testUnknownMakersFallBackToGenericShapes() {
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "PowerWalker", model: "VI 1500 STL"), .genericTower)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Riello", model: "SEP 2200 RACK"), .genericRack)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: nil, model: nil), .genericTower)
        XCTAssertEqual(UPSIllustrationKind.classify(maker: "Tripp Lite", model: "SMART1500LCDT"), .genericTower)
    }
}
