import XCTest
@testable import LogiEasySwitchApp

final class SecurityTests: XCTestCase {
    func testTLSRequiredIncludingOldSavedSettings() throws {
        var settings = MQTTConfiguration()
        settings.enabled = true
        settings.host = "broker.example"
        XCTAssertTrue(settings.useTLS)
        XCTAssertEqual(settings.port, 8883)
        XCTAssertTrue(settings.isUsable)
        let old = Data(#"{"enabled":true,"host":"broker.example","port":1883,"useTLS":false}"#.utf8)
        let decoded = try JSONDecoder().decode(MQTTConfiguration.self, from: old)
        XCTAssertFalse(decoded.isUsable)
        XCTAssertEqual(decoded.topicPrefix, "logi-easy-switch")
        XCTAssertTrue(decoded.validationMessage?.contains("TLS") == true)
    }

    func testCertificateHostnameValidationAndMigration() throws {
        var settings = MQTTConfiguration()
        settings.enabled = true
        settings.host = "homeassistant.local"
        for hostname in ["https://broker.example", "broker.example:8883", "*.example", "bad\0.example", "bad..example", "-bad.example", "bad-.example", String(repeating: "a", count: 64) + ".example"] {
            settings.tlsServerName = hostname
            XCTAssertFalse(settings.isUsable, hostname)
        }
        settings.tlsServerName = "broker.example"
        XCTAssertTrue(settings.isUsable)
        XCTAssertEqual(try JSONDecoder().decode(MQTTConfiguration.self, from: JSONEncoder().encode(settings)), settings)
        let old = try JSONDecoder().decode(MQTTConfiguration.self, from: Data(#"{"enabled":true,"host":"broker.example","useTLS":true}"#.utf8))
        XCTAssertEqual(old.tlsServerName, "")
        XCTAssertTrue(old.isUsable)
    }

    func testNamespacesRejectWildcardsAndPaths() throws {
        var settings = MQTTConfiguration()
        settings.enabled = true
        settings.host = "broker.example"
        for namespace in ["", "other/#", "+", "../", String(repeating: "x", count: 65)] {
            settings.topicPrefix = namespace
            XCTAssertFalse(settings.isUsable, namespace)
        }
        settings.topicPrefix = "work-desk_1"
        XCTAssertTrue(settings.isUsable)
        XCTAssertEqual(try JSONDecoder().decode(MQTTConfiguration.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testMalformedAndOversizedLengthsAreRejectedImmediately() {
        for bytes: [UInt8] in [
            [0x30, 0xff, 0xff, 0xff, 0xff],
            [0x30, 0x81, 0x80, 0x04], // 65,537-byte body
            [0x30, 0x80, 0x00], // noncanonical zero length
        ] {
            var decoder = MQTTPacketDecoder()
            XCTAssertThrowsError(try decoder.append(Data(bytes)))
        }
    }

    func testBufferLimitRejectsExcessiveSingleRead() {
        var decoder = MQTTPacketDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0, count: 100_000)))
    }

    func testFragmentedAndCoalescedMQTTPackets() throws {
        var decoder = MQTTPacketDecoder()
        XCTAssertTrue(try decoder.append(Data([0x20])).isEmpty)
        XCTAssertTrue(decoder.hasPartialPacket)
        XCTAssertTrue(try decoder.append(Data([0x02, 0x00])).isEmpty)
        let packets = try decoder.append(Data([0x00, 0xd0, 0x00]))
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].body, Data([0, 0]))
        XCTAssertEqual(packets[1].header, 0xd0)
        XCTAssertFalse(decoder.hasPartialPacket)
    }

    func testMaximumPacketCanArriveInFragments() throws {
        var decoder = MQTTPacketDecoder()
        XCTAssertTrue(try decoder.append(Data([0x30, 0x80, 0x80, 0x04])).isEmpty)
        for _ in 0..<3 {
            XCTAssertTrue(try decoder.append(Data(repeating: 1, count: 16_384)).isEmpty)
        }
        XCTAssertEqual(try decoder.append(Data(repeating: 1, count: 16_384)).first?.body.count, 65_536)
        XCTAssertFalse(decoder.hasPartialPacket)
    }

    func testPublicationRejectsMalformedTopicsAndUnsupportedQoS() {
        for packet in [
            MQTTPacket(header: 0x30, body: Data([0, 4, 65])),
            MQTTPacket(header: 0x30, body: Data([0, 0])),
            MQTTPacket(header: 0x30, body: Data([0, 1, 0xff])),
            MQTTPacket(header: 0x30, body: Data([0, 1, 0])),
            MQTTPacket(header: 0x30, body: Data([0, 1, 0x23])),
            MQTTPacket(header: 0x32, body: Data([0, 1, 65, 0, 1])),
        ] {
            XCTAssertThrowsError(try packet.publication())
        }
    }

    func testRetainedCommandAndUnknownTargetCannotSwitch() throws {
        let packet = MQTTPacket(header: 0x31, body: Data([0, 1, 65] + Array("Work Mac".utf8)))
        let message = try packet.publication()
        XCTAssertTrue(message.retained)
        XCTAssertNil(MQTTCommandPolicy.acceptedTarget(payload: message.payload, retained: message.retained, targets: ["Work Mac"]))
        XCTAssertEqual(MQTTCommandPolicy.acceptedTarget(payload: message.payload, retained: false, targets: ["Work Mac"]), "Work Mac")
        XCTAssertNil(MQTTCommandPolicy.acceptedTarget(payload: Data("Other Mac".utf8), retained: false, targets: ["Work Mac"]))
        XCTAssertNil(MQTTCommandPolicy.acceptedTarget(payload: Data(repeating: 65, count: 1_025), retained: false, targets: []))
        XCTAssertNil(MQTTCommandPolicy.acceptedTarget(payload: Data([0xff]), retained: false, targets: []))
    }

    func testAllTruncatedHIDReportsRejected() {
        let report: [UInt8] = [0x11, 0xff, 1, 0x0a] + Array(repeating: 0, count: 16)
        for count in 0..<20 {
            XCTAssertThrowsError(try HIDPPResponse.payload(Array(report.prefix(count))))
        }
        XCTAssertEqual(try HIDPPResponse.payload(report).count, 16)
        XCTAssertThrowsError(try HIDPPResponse.payload(report + [0]))
    }

    func testHIDHostCountAndChannelBounds() throws {
        for payload: [UInt8] in [[], [1], [0, 0], [4, 0], [3, 3], [255, 0]] {
            XCTAssertThrowsError(try HIDPPResponse.hostState(payload))
        }
        let state = try HIDPPResponse.hostState([3, 2])
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(state.current, 2)
    }

    func testPlaintextClientFailsBeforeConnecting() {
        var settings = MQTTConfiguration()
        settings.enabled = true
        settings.host = "127.0.0.1"
        settings.useTLS = false
        let rejected = expectation(description: "Insecure connection rejected")
        let client = MQTTClient(configuration: settings, password: "test-only", clientID: "test")
        client.onDisconnected = { error in
            XCTAssertNotNil(error)
            rejected.fulfill()
        }
        client.onConnected = { XCTFail("Plaintext connection must never succeed") }
        client.connect()
        wait(for: [rejected], timeout: 2)
    }
}
