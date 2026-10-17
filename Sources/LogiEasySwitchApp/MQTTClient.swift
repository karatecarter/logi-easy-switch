import Foundation
import Network

final class MQTTClient: @unchecked Sendable {
    enum ClientError: LocalizedError {
        case invalidConfiguration
        case connectionRefused(UInt8)
        case disconnected(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: "The MQTT broker settings are incomplete."
            case .connectionRefused(let code): "The MQTT broker refused the connection (code \(code))."
            case .disconnected(let message): message
            }
        }
    }

    var onConnected: (@Sendable () -> Void)?
    var onMessage: (@Sendable (String, Data) -> Void)?
    var onDisconnected: (@Sendable (Error?) -> Void)?

    private let configuration: MQTTConfiguration
    private let password: String
    private let clientID: String
    private let will: (topic: String, payload: String)?
    private let queue = DispatchQueue(label: "local.logi-easy-switch.mqtt")
    private var connection: NWConnection?
    private var incoming = Data()
    private var keepAlive: DispatchSourceTimer?
    private var nextPacketID: UInt16 = 1
    private(set) var isConnected = false

    init(configuration: MQTTConfiguration, password: String, clientID: String, will: (topic: String, payload: String)? = nil) {
        self.configuration = configuration
        self.password = password
        self.clientID = String(clientID.prefix(64))
        self.will = will
    }

    func connect() {
        guard configuration.isUsable, let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            onDisconnected?(ClientError.invalidConfiguration)
            return
        }
        let parameters: NWParameters = configuration.useTLS ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(configuration.host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRaw(self.connectPacket())
                self.receiveNext()
            case .failed(let error): self.finish(error)
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isConnected { self.sendRaw(Data([0xe0, 0x00])) }
            self.keepAlive?.cancel()
            self.keepAlive = nil
            self.connection?.cancel()
            self.connection = nil
            self.isConnected = false
        }
    }

    func subscribe(_ topic: String) {
        queue.async { [weak self] in
            guard let self, self.isConnected else { return }
            var body = Data()
            let id = self.nextPacketID
            self.nextPacketID = self.nextPacketID == UInt16.max ? 1 : self.nextPacketID + 1
            body.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xff)])
            body.appendMQTTString(topic)
            body.append(0)
            self.sendPacket(header: 0x82, body: body)
        }
    }

    func publish(topic: String, payload: Data, retain: Bool = false) {
        queue.async { [weak self] in
            guard let self, self.isConnected else { return }
            var body = Data()
            body.appendMQTTString(topic)
            body.append(payload)
            self.sendPacket(header: retain ? 0x31 : 0x30, body: body)
        }
    }

    func publish(topic: String, string: String, retain: Bool = false) {
        publish(topic: topic, payload: Data(string.utf8), retain: retain)
    }

    private func connectPacket() -> Data {
        var body = Data()
        body.appendMQTTString("MQTT")
        body.append(4)
        var flags: UInt8 = 0x02
        if will != nil { flags |= 0x24 }
        if !configuration.username.isEmpty || !password.isEmpty { flags |= 0x80 }
        if !password.isEmpty { flags |= 0x40 }
        body.append(flags)
        body.append(contentsOf: [0x00, 0x1e])
        body.appendMQTTString(clientID)
        if let will {
            body.appendMQTTString(will.topic)
            body.appendMQTTString(will.payload)
        }
        if !configuration.username.isEmpty || !password.isEmpty { body.appendMQTTString(configuration.username) }
        if !password.isEmpty { body.appendMQTTString(password) }
        return framedPacket(header: 0x10, body: body)
    }

    private func sendPacket(header: UInt8, body: Data) { sendRaw(framedPacket(header: header, body: body)) }

    private func framedPacket(header: UInt8, body: Data) -> Data {
        var packet = Data([header])
        packet.append(contentsOf: encodeRemainingLength(body.count))
        packet.append(body)
        return packet
    }

    private func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.incoming.append(data); self.parsePackets() }
            if let error { self.finish(error); return }
            if complete { self.finish(nil); return }
            self.receiveNext()
        }
    }

    private func parsePackets() {
        while incoming.count >= 2 {
            guard let length = decodeRemainingLength(incoming, startingAt: 1) else { return }
            let total = 1 + length.byteCount + length.value
            guard incoming.count >= total else { return }
            let header = incoming[0]
            let bodyStart = 1 + length.byteCount
            let body = Data(incoming[bodyStart..<total])
            incoming.removeSubrange(0..<total)
            handlePacket(type: header >> 4, body: body)
        }
    }

    private func handlePacket(type: UInt8, body: Data) {
        switch type {
        case 2:
            guard body.count >= 2 else { return }
            guard body[1] == 0 else { finish(ClientError.connectionRefused(body[1])); return }
            isConnected = true
            startKeepAlive()
            onConnected?()
        case 3:
            guard body.count >= 2 else { return }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            guard body.count >= 2 + topicLength,
                  let topic = String(data: body[2..<(2 + topicLength)], encoding: .utf8) else { return }
            onMessage?(topic, Data(body[(2 + topicLength)...]))
        default: break
        }
    }

    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.sendRaw(Data([0xc0, 0x00])) }
        timer.resume()
        keepAlive = timer
    }

    private func finish(_ error: Error?) {
        let wasActive = connection != nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        keepAlive?.cancel()
        keepAlive = nil
        isConnected = false
        if wasActive { onDisconnected?(error) }
    }
}

private func encodeRemainingLength(_ length: Int) -> [UInt8] {
    var value = length
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(value % 128)
        value /= 128
        if value > 0 { byte |= 0x80 }
        bytes.append(byte)
    } while value > 0
    return bytes
}

private func decodeRemainingLength(_ data: Data, startingAt offset: Int) -> (value: Int, byteCount: Int)? {
    var multiplier = 1
    var value = 0
    var index = offset
    while index < data.count, index < offset + 4 {
        let byte = data[index]
        value += Int(byte & 0x7f) * multiplier
        if byte & 0x80 == 0 { return (value, index - offset + 1) }
        multiplier *= 128
        index += 1
    }
    return nil
}

private extension Data {
    mutating func appendMQTTString(_ string: String) {
        let bytes = Data(string.utf8)
        append(contentsOf: [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)])
        append(bytes)
    }
}
