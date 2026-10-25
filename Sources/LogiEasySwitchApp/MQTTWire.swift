import Foundation

/// Bounded MQTT 3.1.1 framing. A short length is incomplete; a fifth length
/// byte, noncanonical length, or oversized body is a protocol error.
struct MQTTPacketDecoder {
    static let maximumBodySize = 65_536
    private(set) var buffered = Data()
    var hasPartialPacket: Bool { !buffered.isEmpty }

    mutating func append(_ data: Data) throws -> [MQTTPacket] {
        guard buffered.count + data.count <= Self.maximumBodySize + 5 + 16_384 else {
            throw LogiError.protocolError("MQTT receive buffer exceeds the limit.")
        }
        buffered.append(data)
        var packets: [MQTTPacket] = []
        while buffered.count >= 2 {
            let bytes = [UInt8](buffered.prefix(5))
            var length = 0
            var multiplier = 1
            var lengthBytes = 0
            for index in 1..<bytes.count {
                let byte = bytes[index]
                length += Int(byte & 0x7f) * multiplier
                guard length <= Self.maximumBodySize else {
                    throw LogiError.protocolError("MQTT packet exceeds the limit.")
                }
                if byte & 0x80 == 0 {
                    guard index == 1 || byte != 0 else {
                        throw LogiError.protocolError("Noncanonical MQTT length.")
                    }
                    lengthBytes = index
                    break
                }
                guard index < 4 else { throw LogiError.protocolError("Malformed MQTT length.") }
                multiplier *= 128
            }
            guard lengthBytes > 0 else { break }
            let bodyStart = 1 + lengthBytes
            let total = bodyStart + length
            guard buffered.count >= total else { break }
            packets.append(MQTTPacket(header: bytes[0], body: Data(buffered.dropFirst(bodyStart).prefix(length))))
            buffered = Data(buffered.dropFirst(total))
        }
        return packets
    }
}

struct MQTTPacket {
    let header: UInt8
    let body: Data

    func publication() throws -> (topic: String, payload: Data, retained: Bool) {
        // Subscriptions request QoS 0. Reject unexpected QoS/DUP flags rather
        // than accidentally interpreting a packet identifier as payload.
        guard header >> 4 == 3, header & 0x0e == 0, body.count >= 2 else {
            throw LogiError.protocolError("Invalid MQTT publication.")
        }
        let bytes = [UInt8](body)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, bytes.count >= 2 + length,
              let topic = String(bytes: bytes[2..<(2 + length)], encoding: .utf8),
              !topic.contains("\0"), !topic.contains("#"), !topic.contains("+") else {
            throw LogiError.protocolError("Invalid MQTT topic.")
        }
        return (topic, Data(bytes.dropFirst(2 + length)), header & 1 != 0)
    }
}

/// Broker ACLs authorize publishers. This policy additionally rejects retained
/// commands and targets that are not explicitly configured on this Mac.
enum MQTTCommandPolicy {
    static func acceptedTarget(payload: Data, retained: Bool, targets: [String]) -> String? {
        guard !retained, payload.count <= 1_024,
              let value = String(data: payload, encoding: .utf8) else { return nil }
        return targets.first { $0 == value }
    }
}
