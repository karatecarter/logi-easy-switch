import Foundation

/// Long HID++ reports have exactly 20 bytes, including a 4-byte header.
/// Validate the wire length before any feature-specific indexing or slicing.
enum HIDPPResponse {
    static func payload(_ report: [UInt8]) throws -> [UInt8] {
        guard report.count == 20, report[0] == 0x11, report[1] == 0xff else {
            throw LogiError.protocolError("Malformed HID++ long report.")
        }
        return Array(report[4..<20])
    }

    static func hostState(_ payload: [UInt8]) throws -> (count: Int, current: Int) {
        guard payload.count >= 2, (1...3).contains(Int(payload[0])), payload[1] < payload[0] else {
            throw LogiError.protocolError("Invalid HID++ host count or current channel.")
        }
        return (Int(payload[0]), Int(payload[1]))
    }
}
