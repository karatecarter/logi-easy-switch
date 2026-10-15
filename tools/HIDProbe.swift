import Foundation
import IOKit.hid

private let keys: [(String, CFString)] = [
    ("product", kIOHIDProductKey as CFString),
    ("manufacturer", kIOHIDManufacturerKey as CFString),
    ("transport", kIOHIDTransportKey as CFString),
    ("vendorID", kIOHIDVendorIDKey as CFString),
    ("productID", kIOHIDProductIDKey as CFString),
    ("usagePage", kIOHIDPrimaryUsagePageKey as CFString),
    ("usage", kIOHIDPrimaryUsageKey as CFString),
    ("maxInput", kIOHIDMaxInputReportSizeKey as CFString),
    ("maxOutput", kIOHIDMaxOutputReportSizeKey as CFString),
    ("maxFeature", kIOHIDMaxFeatureReportSizeKey as CFString),
    ("locationID", kIOHIDLocationIDKey as CFString),
    ("serial", kIOHIDSerialNumberKey as CFString),
]

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046d] as CFDictionary)

guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    fputs("Could not open IOHIDManager\n", stderr)
    exit(1)
}

let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [])
let rows: [[String: Any]] = devices.map { device in
    var row: [String: Any] = [:]
    for (name, key) in keys {
        if let value = IOHIDDeviceGetProperty(device, key) {
            row[name] = value
        }
    }
    row["registryID"] = IOHIDDeviceGetService(device)
    return row
}.sorted {
    String(describing: $0["registryID"] ?? "") < String(describing: $1["registryID"] ?? "")
}

let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
