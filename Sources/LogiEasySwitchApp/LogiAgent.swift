import Darwin
import Foundation

struct LogiAgent: Sendable {
    private let socketPrefix = "logitech_kiros_agent-"

    func devices() throws -> [LogiDevice] {
        let response = try request(verb: "GET", path: "/devices/list")
        let values = collectDevices(in: response)
        return Array(Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { existing, candidate in
            candidate.connected ? candidate : existing
        }).values)
            .filter { ["MOUSE", "KEYBOARD"].contains($0.type) && $0.id.hasPrefix("dev") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func hosts(for device: LogiDevice) throws -> [LogiHost] {
        let response = try request(verb: "GET", path: "/devices/\(device.id)/easy_switch")
        guard let payload = response["payload"] as? [String: Any],
              let hostValues = payload["hosts"] as? [[String: Any]] else {
            throw LogiError.protocolError("Options+ did not return Easy-Switch hosts for \(device.name).")
        }
        return hostValues.compactMap { value in
            guard let index = value["index"] as? Int,
                  let name = value["name"] as? String,
                  let paired = value["paired"] as? Bool,
                  let connected = value["connected"] as? Bool else { return nil }
            return LogiHost(index: index, name: name, paired: paired, connected: connected)
        }.filter(\.paired)
    }

    func switchDevice(_ device: LogiDevice, to host: LogiHost) throws {
        let payload: [String: Any] = [
            "@type": "type.googleapis.com/logi.protocol.devices.ChangeHost",
            "host": host.index,
        ]
        _ = try request(verb: "SET", path: "/change_host/\(device.id)/host", payload: payload)
    }

    private func request(verb: String, path: String, payload: [String: Any]? = nil) throws -> [String: Any] {
        let messageID = UUID().uuidString
        var request: [String: Any] = ["msg_id": messageID, "verb": verb, "path": path]
        if let payload { request["payload"] = payload }
        let socket = try connect()
        defer { close(socket) }
        try writeAll(encode(request), to: socket)

        while true {
            let frame = try readFrame(from: socket)
            guard frame.protocolName == "json" else { continue }
            guard let object = try JSONSerialization.jsonObject(with: frame.message) as? [String: Any] else {
                throw LogiError.protocolError("Options+ returned a non-object JSON response.")
            }
            let receivedID = object["msgId"] as? String ?? object["msg_id"] as? String
            guard receivedID == messageID else { continue }
            if let result = object["result"] as? [String: Any],
               let code = result["code"] as? String, code != "SUCCESS" {
                throw LogiError.requestFailed("\(code): \(result["what"] as? String ?? path)")
            }
            return object
        }
    }

    private func collectDevices(in value: Any) -> [LogiDevice] {
        var result: [LogiDevice] = []
        if let array = value as? [Any] {
            for child in array { result += collectDevices(in: child) }
        } else if let dictionary = value as? [String: Any] {
            if let id = dictionary["id"] as? String,
               let name = (dictionary["name"] ?? dictionary["displayName"] ?? dictionary["deviceName"]) as? String,
               let type = dictionary["deviceType"] as? String {
                result.append(LogiDevice(
                    id: id,
                    name: name,
                    type: type,
                    state: dictionary["state"] as? String ?? "UNKNOWN",
                    connected: dictionary["connected"] as? Bool ?? false
                ))
            }
            for child in dictionary.values { result += collectDevices(in: child) }
        }
        return result
    }

    private func connect() throws -> Int32 {
        let paths = try FileManager.default.contentsOfDirectory(atPath: "/tmp")
            .filter { $0.hasPrefix(socketPrefix) && !$0.hasSuffix(".real") }
            .sorted()
        guard let name = paths.last else {
            throw LogiError.unavailable("Logi Options+ is not running.")
        }
        let path = "/tmp/\(name)"
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LogiError.unavailable("Could not open the Options+ socket.") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw LogiError.unavailable("Options+ socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { bytes[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 else {
            close(fd)
            throw LogiError.unavailable("Could not connect to Logi Options+ (\(String(cString: strerror(errno)))).")
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        return fd
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        let message = try JSONSerialization.data(withJSONObject: object)
        let proto = Data("json".utf8)
        var inner = Data()
        inner.appendUInt32(UInt32(proto.count), endian: .big)
        inner.append(proto)
        inner.appendUInt32(UInt32(message.count), endian: .big)
        inner.append(message)
        var frame = Data()
        frame.appendUInt32(UInt32(inner.count), endian: .little)
        frame.append(inner)
        return frame
    }

    private func readFrame(from fd: Int32) throws -> (protocolName: String, message: Data) {
        let outerLength = try readExactly(4, from: fd).uint32(at: 0, endian: .little)
        guard outerLength > 8, outerLength < 1_000_000 else {
            throw LogiError.protocolError("Invalid Options+ frame size.")
        }
        let inner = try readExactly(Int(outerLength), from: fd)
        let protoLength = inner.uint32(at: 0, endian: .big)
        let protoStart = 4
        let protoEnd = protoStart + Int(protoLength)
        guard protoEnd + 4 <= inner.count else { throw LogiError.protocolError("Malformed Options+ frame.") }
        let name = String(data: inner[protoStart..<protoEnd], encoding: .utf8) ?? ""
        let messageLength = inner.uint32(at: protoEnd, endian: .big)
        let messageStart = protoEnd + 4
        let messageEnd = messageStart + Int(messageLength)
        guard messageEnd <= inner.count else { throw LogiError.protocolError("Malformed Options+ message.") }
        return (name, Data(inner[messageStart..<messageEnd]))
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < data.count {
                let result = Darwin.send(fd, buffer.baseAddress!.advanced(by: written), data.count - written, 0)
                guard result > 0 else { throw LogiError.unavailable("Writing to Logi Options+ failed.") }
                written += result
            }
        }
    }

    private func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let result = data.withUnsafeMutableBytes { buffer in
                Darwin.recv(fd, buffer.baseAddress!.advanced(by: received), count - received, 0)
            }
            guard result > 0 else { throw LogiError.unavailable("Logi Options+ did not respond.") }
            received += result
        }
        return data
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32, endian: Endianness) {
        var adjusted = endian == .big ? value.bigEndian : value.littleEndian
        append(Data(bytes: &adjusted, count: MemoryLayout<UInt32>.size))
    }

    func uint32(at offset: Int, endian: Endianness) -> UInt32 {
        let value = self[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return endian == .big ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }
}

private enum Endianness { case big, little }
