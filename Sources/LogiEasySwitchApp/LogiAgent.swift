import Foundation

/// The app-facing device service. Communication is direct HID++ over IOKit;
/// Logi Options+ is not involved.
struct LogiAgent: Sendable {
    func devices() throws -> [LogiDevice] {
        try HIDPPTransport().devices()
    }

    func hosts(for device: LogiDevice) throws -> [LogiHost] {
        try HIDPPTransport().hosts(for: device)
    }

    func switchDevice(_ device: LogiDevice, to host: LogiHost) throws {
        try HIDPPTransport().switchDevice(device, to: host.index)
    }

    func switchDevices(_ targets: [(LogiDevice, LogiHost)]) throws {
        try HIDPPTransport().switchDevices(targets.map { ($0.0, $0.1.index) })
    }
}
