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
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    func configure(_ configuration: USBTriggerConfiguration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        wasPresent = isPresent(configuration.deviceID)
        stopNotifications()
        guard configuration.isUsable else { return }
        startNotifications()
    }

    func stop() {
        stopNotifications()
    }

    fileprivate func registryChanged() {
        let present = isPresent(configuration.deviceID)
        if present && !wasPresent { onConnect?() }
        wasPresent = present
    }

    private func isPresent(_ id: String) -> Bool {
        USBDeviceDiscovery.devices().contains { $0.id == id }
    }

    private func startNotifications() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()

        let addedResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"),
            usbRegistryNotification,
            context,
            &addedIterator
        )
        if addedResult == KERN_SUCCESS { drainUSBIterator(addedIterator) }

        let removedResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            usbRegistryNotification,
            context,
            &removedIterator
        )
        if removedResult == KERN_SUCCESS { drainUSBIterator(removedIterator) }
    }

    private func stopNotifications() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }
}

private func drainUSBIterator(_ iterator: io_iterator_t) {
    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return }
        IOObjectRelease(service)
    }
}

private let usbRegistryNotification: IOServiceMatchingCallback = { context, iterator in
    drainUSBIterator(iterator)
    guard let context else { return }
    let monitor = Unmanaged<USBTriggerMonitor>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
        MainActor.assumeIsolated {
            monitor.registryChanged()
        }
    }
}
