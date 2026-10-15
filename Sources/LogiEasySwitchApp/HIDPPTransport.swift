import Foundation
import IOKit.hid

private let logitechVendorID = 0x046d
private let longReportID: UInt8 = 0x11
private let longReportLength = 20
private let directDeviceIndex: UInt8 = 0xff
private let softwareID: UInt8 = 0x0a
private let changeHostFeature: UInt16 = 0x1814
private let hostsInfoFeature: UInt16 = 0x1815

struct HIDPPTransport {
    static func requestInputMonitoringAccessIfNeeded() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown else { return }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func devices() throws -> [LogiDevice] {
        try candidates().compactMap { candidate in
            guard let type = candidate.type else { return nil }
            return try withSession(candidate) { session in
                guard try featureIndex(changeHostFeature, session: session) != nil else { return nil }
                return LogiDevice(id: candidate.id, name: candidate.name, type: type, state: "ACTIVE", connected: true)
            }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func hosts(for device: LogiDevice) throws -> [LogiHost] {
        guard let candidate = try candidates().first(where: { $0.id == device.id }) else {
            throw LogiError.unavailable("\(device.name) is not connected to this Mac.")
        }
        return try withSession(candidate) { session in
            guard let changeIndex = try featureIndex(changeHostFeature, session: session) else {
                throw LogiError.protocolError("\(device.name) does not support Easy-Switch.")
            }
            let changeState = try session.request(feature: changeIndex, function: 0)
            let hostCount = Int(changeState[0])
            let currentHost = Int(changeState[1])

            guard let infoIndex = try featureIndex(hostsInfoFeature, session: session) else {
                return (0..<hostCount).map {
                    LogiHost(index: $0, name: "Channel \($0 + 1)", paired: true, connected: $0 == currentHost)
                }
            }
            let infoState = try session.request(feature: infoIndex, function: 0)
            let canReadNames = infoState[0] & 0x01 != 0
            var result: [LogiHost] = []
            for host in 0..<hostCount {
                let info = try session.request(feature: infoIndex, function: 1, parameters: [UInt8(host)])
                let paired = info[1] != 0
                guard paired else { continue }
                let nameLength = Int(info[4])
                var name = ""
                if canReadNames && nameLength > 0 {
                    var bytes: [UInt8] = []
                    for offset in stride(from: 0, to: nameLength, by: 14) {
                        let piece = try session.request(feature: infoIndex, function: 3, parameters: [UInt8(host), UInt8(offset)])
                        bytes.append(contentsOf: piece[2..<(2 + min(14, nameLength - offset))])
                    }
                    name = String(bytes: bytes, encoding: .utf8) ?? ""
                }
                if name.isEmpty { name = "Channel \(host + 1)" }
                result.append(LogiHost(index: host, name: name, paired: true, connected: host == currentHost))
            }
            return result
        }
    }

    func switchDevice(_ device: LogiDevice, to host: Int) throws {
        guard let candidate = try candidates().first(where: { $0.id == device.id }) else {
            throw LogiError.unavailable("\(device.name) is not connected to this Mac.")
        }
        try withSession(candidate) { session in
            guard let index = try featureIndex(changeHostFeature, session: session) else {
                throw LogiError.protocolError("\(device.name) does not support Easy-Switch.")
            }
            // CHANGE_HOST.setHost deliberately disconnects before a reply can arrive.
            try session.send(feature: index, function: 1, parameters: [UInt8(host)])
        }
    }

    private func featureIndex(_ feature: UInt16, session: HIDPPSession) throws -> UInt8? {
        let response = try session.request(feature: 0, function: 0, parameters: [UInt8(feature >> 8), UInt8(feature & 0xff)])
        return response[0] == 0 ? nil : response[0]
    }

    private func candidates() throws -> [HIDCandidate] {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw LogiError.unavailable("Allow Logi Easy Switch in System Settings → Privacy & Security → Input Monitoring, then relaunch it.")
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: logitechVendorID] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw LogiError.unavailable("Could not access Logitech HID devices.")
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return devices.compactMap { device in
            guard numberProperty(device, kIOHIDVendorIDKey) == logitechVendorID,
                  numberProperty(device, kIOHIDMaxOutputReportSizeKey) >= longReportLength,
                  let name = stringProperty(device, kIOHIDProductKey) else { return nil }
            let productID = numberProperty(device, kIOHIDProductIDKey)
            let serial = stringProperty(device, kIOHIDSerialNumberKey) ?? String(IOHIDDeviceGetService(device))
            let usage = numberProperty(device, kIOHIDPrimaryUsageKey)
            return HIDCandidate(
                device: device,
                id: String(format: "hid:%04x:%@", productID, serial),
                name: name,
                type: usage == 2 ? "MOUSE" : (usage == 6 ? "KEYBOARD" : nil)
            )
        }
    }

    private func withSession<T>(_ candidate: HIDCandidate, _ body: (HIDPPSession) throws -> T) throws -> T {
        let session = try HIDPPSession(device: candidate.device)
        defer { session.close() }
        return try body(session)
    }

    private func numberProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

private struct HIDCandidate {
    let device: IOHIDDevice
    let id: String
    let name: String
    let type: String?
}

private final class HIDPPSession {
    private let device: IOHIDDevice
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var reports: [[UInt8]] = []
    private var isOpen = false

    init(device: IOHIDDevice) throws {
        self.device = device
        inputBuffer.initialize(repeating: 0, count: 64)
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            inputBuffer.deallocate()
            throw LogiError.unavailable("macOS denied access to the Logitech device. Allow Logi Easy Switch in Privacy & Security > Input Monitoring, then relaunch it.")
        }
        isOpen = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, hidInputCallback, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        close()
        inputBuffer.deallocate()
    }

    func close() {
        guard isOpen else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
    }

    func request(feature: UInt8, function: UInt8, parameters: [UInt8] = []) throws -> [UInt8] {
        try send(feature: feature, function: function, parameters: parameters)
        let functionAndSoftwareID = (function << 4) | softwareID
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            while !reports.isEmpty {
                let report = reports.removeFirst()
                guard report.count >= 6, report[0] == longReportID, report[1] == directDeviceIndex else { continue }
                if report[2] == 0xff, report[3] == feature, report[4] == functionAndSoftwareID {
                    throw LogiError.requestFailed("HID++ error \(report[5]) from the Logitech device.")
                }
                if report[2] == feature, report[3] == functionAndSoftwareID {
                    return Array(report[4..<min(report.count, longReportLength)])
                }
            }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, true)
        }
        throw LogiError.unavailable("\(productName) did not respond to HID++.")
    }

    func send(feature: UInt8, function: UInt8, parameters: [UInt8] = []) throws {
        guard parameters.count <= 16 else { throw LogiError.protocolError("HID++ request is too large.") }
        var frame = [UInt8](repeating: 0, count: longReportLength)
        frame[0] = longReportID
        frame[1] = directDeviceIndex
        frame[2] = feature
        frame[3] = (function << 4) | softwareID
        frame.replaceSubrange(4..<(4 + parameters.count), with: parameters)
        let count = frame.count
        let result = frame.withUnsafeMutableBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(longReportID), $0.baseAddress!, count)
        }
        guard result == kIOReturnSuccess else {
            throw LogiError.unavailable("Could not write to \(productName) (IOKit \(String(format: "0x%08x", result))).")
        }
    }

    fileprivate func receive(_ report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length > 0 else { return }
        reports.append(Array(UnsafeBufferPointer(start: report, count: length)))
    }

    private var productName: String {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech device"
    }
}

private let hidInputCallback: IOHIDReportCallback = { context, result, _, _, _, report, length in
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<HIDPPSession>.fromOpaque(context).takeUnretainedValue().receive(report, length: length)
}
