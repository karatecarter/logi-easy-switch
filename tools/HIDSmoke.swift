import Foundation

@main
struct HIDSmoke {
    static func main() throws {
        let transport = HIDPPTransport()
        for device in try transport.devices() {
            print("\(device.name) [\(device.id)]")
            for host in try transport.hosts(for: device) {
                print("  \(host.index + 1): \(host.name)\(host.connected ? " (current)" : "")")
            }
        }
    }
}
