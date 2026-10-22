import XCTest
import SquirrelCore

final class NUTDiscoverySubnetTests: XCTestCase {
    /// 192.168.1.42/24 → .1 through .254, with this Mac left out.
    func testASlash24YieldsEveryHostExceptItself() {
        let subnet = NUTDiscovery.LocalSubnet(address: address("192.168.1.42"), prefixLength: 24)
        let hosts = subnet.candidateAddresses(maximumHosts: 256).map(NUTDiscovery.ipv4String)

        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.42"))
        XCTAssertFalse(hosts.contains("192.168.1.0"))
        XCTAssertFalse(hosts.contains("192.168.1.255"))
    }

    /// A gateway at .1 is the likely NUT host, so it must be probed.
    func testIncludesTheGatewayAddress() {
        let subnet = NUTDiscovery.LocalSubnet(address: address("10.0.0.7"), prefixLength: 24)
        XCTAssertTrue(subnet.candidateAddresses(maximumHosts: 256).map(NUTDiscovery.ipv4String).contains("10.0.0.1"))
    }

    /// A /16 must not become a 65,000-address sweep; it is clamped to the /24
    /// this Mac is actually sitting in.
    func testWideNetworksAreClampedToTheLocalSlash24() {
        let subnet = NUTDiscovery.LocalSubnet(address: address("172.16.5.9"), prefixLength: 16)
        let hosts = subnet.candidateAddresses(maximumHosts: 256).map(NUTDiscovery.ipv4String)

        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "172.16.5.1")
        XCTAssertEqual(hosts.last, "172.16.5.254")
    }

    /// A narrower mask is honoured rather than widened back out.
    func testNarrowNetworksKeepTheirOwnMask() {
        let subnet = NUTDiscovery.LocalSubnet(address: address("192.168.1.130"), prefixLength: 25)
        let hosts = subnet.candidateAddresses(maximumHosts: 256).map(NUTDiscovery.ipv4String)

        XCTAssertEqual(hosts.first, "192.168.1.129")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.1"))
    }

    /// A point-to-point style /31 or /32 has no hosts worth probing.
    func testPointToPointNetworksYieldNothing() {
        XCTAssertTrue(NUTDiscovery.LocalSubnet(address: address("10.1.1.1"), prefixLength: 31)
            .candidateAddresses(maximumHosts: 256).isEmpty)
        XCTAssertTrue(NUTDiscovery.LocalSubnet(address: address("10.1.1.1"), prefixLength: 32)
            .candidateAddresses(maximumHosts: 256).isEmpty)
    }

    func testFormatsAddressesBackToDottedQuad() {
        XCTAssertEqual(NUTDiscovery.ipv4String(address("192.168.1.1")), "192.168.1.1")
        XCTAssertEqual(NUTDiscovery.ipv4String(address("255.255.255.255")), "255.255.255.255")
        XCTAssertEqual(NUTDiscovery.ipv4String(0), "0.0.0.0")
    }

    private func address(_ dotted: String) -> UInt32 {
        dotted.split(separator: ".").reduce(UInt32(0)) { $0 << 8 | UInt32($1)! }
    }
}

final class NUTErrorMessageTests: XCTestCase {
    /// Onboarding shows these to people who have never heard of NUT, so none
    /// of them may be a raw enum case.
    func testEveryFriendlyMessageIsASentence() {
        let errors: [NUTError] = [
            .accessDenied, .unknownUPS, .dataStale, .driverNotConnected,
            .usernameRequired, .invalidPassword, .connectionFailed("refused"),
            .timedOut, .malformedResponse("junk"), .featureNotSupported,
        ]
        for error in errors {
            let message = error.friendlyDescription
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.hasSuffix("."), "\(error) → \(message)")
            XCTAssertEqual(message.first, message.first?.uppercased().first)
        }
    }

    func testCredentialFailuresAreIdentifiedAsSuch() {
        XCTAssertTrue(NUTError.accessDenied.isAuthenticationProblem)
        XCTAssertTrue(NUTError.usernameRequired.isAuthenticationProblem)
        XCTAssertTrue(NUTError.invalidPassword.isAuthenticationProblem)
        XCTAssertFalse(NUTError.dataStale.isAuthenticationProblem)
        XCTAssertFalse(NUTError.connectionFailed("refused").isAuthenticationProblem)
    }
}

final class LocalSubnetContainmentTests: XCTestCase {
    func testASubnetContainsItsOwnHostsOnly() {
        let subnet = NUTDiscovery.LocalSubnet(address: 0x0A0B_0114, prefixLength: 24) // 10.11.1.20/24
        XCTAssertTrue(subnet.contains(0x0A0B_012E))  // 10.11.1.46
        XCTAssertFalse(subnet.contains(0x0A0B_022E)) // 10.11.2.46
    }
}
