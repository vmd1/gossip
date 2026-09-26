import XCTest
@testable import Gossip

/// Covers the pure, device-independent logic in `ADBWirelessPairing`: QR
/// payload construction, `adb mdns services`/`adb devices -l` output
/// parsing, and the IP-based device-identity cross-check. None of this
/// requires a real `adb` binary or a connected device.
final class ADBWirelessPairingTests: XCTestCase {

    // MARK: - QR payload

    func testQRPayloadFormat() {
        let payload = ADBWirelessPairing.qrPayload(serviceName: "connect-deadbeef", pairingCode: "123456")
        XCTAssertEqual(payload, "WIFI:T:ADB;S:connect-deadbeef;P:123456;;")
    }

    func testRandomServiceSuffixLengthAndAlphabet() {
        let suffix = ADBWirelessPairing.randomServiceSuffix(length: 8)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testRandomPairingCodeIsSixDigits() {
        for _ in 0..<20 {
            let code = ADBWirelessPairing.randomPairingCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertNotNil(Int(code))
        }
    }

    // MARK: - `adb mdns services` parsing

    func testParseMDNSAddressFindsMatchingPairingService() {
        // Real `adb mdns services` output is 3 whitespace-separated columns:
        // <instance name>  <service type>  <address:port>.
        let output = """
        List of discovered mdns services
        adb-1234567890AB-XXXXXX\t_adb-tls-connect._tcp\t192.168.1.23:41000
        adb-1234567890AB-YYYYYY\t_adb-tls-pairing._tcp\t192.168.1.23:42000
        """
        let address = ADBWirelessPairing.parseMDNSAddress(output, serviceType: "_adb-tls-pairing._tcp")
        XCTAssertEqual(address, "192.168.1.23:42000")
    }

    func testParseMDNSAddressFindsConnectService() {
        let output = """
        List of discovered mdns services
        adb-1234567890AB-YYYYYY\t_adb-tls-pairing._tcp\t192.168.1.23:42000
        adb-1234567890AB-XXXXXX\t_adb-tls-connect._tcp\t192.168.1.23:5555
        """
        let address = ADBWirelessPairing.parseMDNSAddress(output, serviceType: "_adb-tls-connect._tcp")
        XCTAssertEqual(address, "192.168.1.23:5555")
    }

    func testParseMDNSAddressReturnsNilWhenNoServicesFound() {
        let output = "List of discovered mdns services\n"
        XCTAssertNil(ADBWirelessPairing.parseMDNSAddress(output, serviceType: "_adb-tls-pairing._tcp"))
    }

    func testParseMDNSAddressIgnoresUnrelatedServiceTypes() {
        let output = """
        List of discovered mdns services
        somedevice._adb._tcp.  192.168.1.5:5555
        """
        XCTAssertNil(ADBWirelessPairing.parseMDNSAddress(output, serviceType: "_adb-tls-pairing._tcp"))
    }

    // MARK: - `adb devices -l` parsing

    func testParseAuthorizedSerialMatchesConnectedDeviceState() {
        let output = """
        List of devices attached
        192.168.1.23:5555     device product:r11sxeea model:SM_S711B device:r11s transport_id:4
        """
        let serial = ADBWirelessPairing.parseAuthorizedSerial(output, matching: "192.168.1.23:5555")
        XCTAssertEqual(serial, "192.168.1.23:5555")
    }

    func testParseAuthorizedSerialReturnsNilWhenUnauthorized() {
        let output = """
        List of devices attached
        192.168.1.23:5555     unauthorized transport_id:4
        """
        XCTAssertNil(ADBWirelessPairing.parseAuthorizedSerial(output, matching: "192.168.1.23:5555"))
    }

    func testParseAuthorizedSerialReturnsNilWhenOffline() {
        let output = """
        List of devices attached
        192.168.1.23:5555     offline
        """
        XCTAssertNil(ADBWirelessPairing.parseAuthorizedSerial(output, matching: "192.168.1.23:5555"))
    }

    func testFirstAuthorizedSerialSkipsUnauthorizedAndReturnsFirstDevice() {
        let output = """
        List of devices attached
        192.168.1.9:5555      unauthorized
        R5CWB1SSLMJ            device usb:1048576X product:r11sxeea model:SM_S711B device:r11s transport_id:3
        """
        XCTAssertEqual(ADBWirelessPairing.firstAuthorizedSerial(output), "R5CWB1SSLMJ")
    }

    func testFirstAuthorizedSerialReturnsNilWhenNoneAuthorized() {
        let output = """
        List of devices attached
        192.168.1.9:5555      offline
        """
        XCTAssertNil(ADBWirelessPairing.firstAuthorizedSerial(output))
    }

    // MARK: - Device-identity verification

    func testVerifyMatchesTrustedPeerTrueWhenIPsMatch() {
        let matches = ADBWirelessPairing.verifyMatchesTrustedPeer(
            discoveredAddress: "192.168.1.23:5555",
            trustedPeerIP: "192.168.1.23"
        )
        XCTAssertTrue(matches)
    }

    func testVerifyMatchesTrustedPeerFalseWhenIPsDiffer() {
        let matches = ADBWirelessPairing.verifyMatchesTrustedPeer(
            discoveredAddress: "192.168.1.99:5555",
            trustedPeerIP: "192.168.1.23"
        )
        XCTAssertFalse(matches)
    }

    func testVerifyMatchesTrustedPeerFalseWhenNoTrustedPeer() {
        let matches = ADBWirelessPairing.verifyMatchesTrustedPeer(
            discoveredAddress: "192.168.1.23:5555",
            trustedPeerIP: nil
        )
        XCTAssertFalse(matches)
    }

    func testVerifyMatchesTrustedPeerFalseWhenTrustedPeerIPEmpty() {
        let matches = ADBWirelessPairing.verifyMatchesTrustedPeer(
            discoveredAddress: "192.168.1.23:5555",
            trustedPeerIP: ""
        )
        XCTAssertFalse(matches)
    }
}
