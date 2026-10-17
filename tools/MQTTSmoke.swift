import Foundation

@main
struct MQTTSmoke {
    static func main() {
        var configuration = MQTTConfiguration()
        configuration.enabled = true
        configuration.host = "127.0.0.1"
        configuration.port = 18884
        let client = MQTTClient(configuration: configuration, password: "", clientID: "logi-easy-switch-smoke")
        let finished = DispatchSemaphore(value: 0)
        var succeeded = false
        client.onConnected = {
            client.subscribe("logi-easy-switch/smoke")
            client.publish(topic: "logi-easy-switch/smoke", string: "hello")
        }
        client.onMessage = { topic, payload in
            if topic == "logi-easy-switch/smoke", String(data: payload, encoding: .utf8) == "hello" {
                succeeded = true
                finished.signal()
            }
        }
        client.onDisconnected = { error in
            if let error { fputs("\(error.localizedDescription)\n", stderr) }
            finished.signal()
        }
        client.connect()
        guard finished.wait(timeout: .now() + 5) == .success, succeeded else {
            fputs("MQTT smoke test failed\n", stderr)
            exit(1)
        }
        client.disconnect()
        print("MQTT connect, subscribe, publish, and receive passed")
    }
}
