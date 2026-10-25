import Foundation

@main
struct MQTTSmoke {
    static func main() {
        var configuration = MQTTConfiguration()
        configuration.enabled = true
        // Use an approved TLS broker with a system-trusted certificate.
        let environment = ProcessInfo.processInfo.environment
        configuration.host = environment["LOGI_TEST_MQTT_HOST"] ?? "localhost"
        configuration.port = Int(environment["LOGI_TEST_MQTT_PORT"] ?? "8883") ?? 8883
        configuration.username = environment["LOGI_TEST_MQTT_USERNAME"] ?? ""
        configuration.tlsServerName = environment["LOGI_TEST_MQTT_TLS_SERVER_NAME"] ?? ""
        let client = MQTTClient(configuration: configuration, password: environment["LOGI_TEST_MQTT_PASSWORD"] ?? "", clientID: "logi-easy-switch-smoke")
        let finished = DispatchSemaphore(value: 0)
        let result = SmokeResult()
        client.onConnected = {
            client.subscribe("logi-easy-switch/smoke")
            client.publish(topic: "logi-easy-switch/smoke", string: "hello")
        }
        client.onMessage = { topic, payload, _ in
            if topic == "logi-easy-switch/smoke", String(data: payload, encoding: .utf8) == "hello" {
                result.markSucceeded()
                finished.signal()
            }
        }
        client.onDisconnected = { error in
            if let error { fputs("\(error.localizedDescription)\n", stderr) }
            finished.signal()
        }
        client.connect()
        guard finished.wait(timeout: .now() + 5) == .success, result.succeeded else {
            fputs("MQTT smoke test failed\n", stderr)
            exit(1)
        }
        client.disconnect()
        print("MQTT connect, subscribe, publish, and receive passed")
    }
}

private final class SmokeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var succeeded: Bool { lock.withLock { value } }
    func markSucceeded() { lock.withLock { value = true } }
}
