import Foundation
import IOKit

struct USBTriggerConfiguration: Codable, Equatable {
    var enabled = false
    var deviceID = ""
    var deviceName = ""

    var isUsable: Bool { enabled && !deviceID.isEmpty }
}

struct USBDeviceDescriptor: Identifiable, Hashable {
    let id: String
    let name: String
}

enum USBDeviceDiscovery {
    static func devices() -> [USBDeviceDescriptor] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var results: [USBDeviceDescriptor] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let values = properties?.takeRetainedValue() as? [String: Any],
                  let vendor = number(values["idVendor"]),
                  let product = number(values["idProduct"]) else { continue }

            let serial = string(values["USB Serial Number"])
            let productName = string(values["USB Product Name"]) ?? string(values["Product Name"]) ?? "USB Device"
            let manufacturer = string(values["USB Vendor Name"]) ?? string(values["Manufacturer"])
            let name = manufacturer.map { "\($0) \(productName)" } ?? productName
            let id = String(format: "%04x:%04x:%@", vendor, product, serial ?? "")
            results.append(USBDeviceDescriptor(id: id, name: name))
        }

        return Array(Set(results)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}

@MainActor
final class USBTriggerMonitor {
    var onConnect: (() -> Void)?
    private var configuration = USBTriggerConfiguration()
    private var wasPresent = false
    private var timer: Timer?

    func configure(_ configuration: USBTriggerConfiguration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        wasPresent = isPresent(configuration.deviceID)
        timer?.invalidate()
        timer = nil
        guard configuration.isUsable else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let present = isPresent(configuration.deviceID)
        if present && !wasPresent { onConnect?() }
        wasPresent = present
    }

    private func isPresent(_ id: String) -> Bool {
        USBDeviceDiscovery.devices().contains { $0.id == id }
    }
}
