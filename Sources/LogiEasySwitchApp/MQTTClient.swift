import Foundation
import Network
import Security

final class MQTTClient: @unchecked Sendable {
    enum ClientError: LocalizedError {
        case invalidConfiguration
        case connectionRefused(UInt8)
        case disconnected(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: "MQTT requires TLS and valid broker settings within the supported lengths."
            case .connectionRefused(let code): "The MQTT broker refused the connection (code \(code))."
            case .disconnected(let message): message
            }
        }
    }

    var onConnected: (@Sendable () -> Void)?
    var onMessage: (@Sendable (String, Data, Bool) -> Void)?
    var onDisconnected: (@Sendable (Error?) -> Void)?

    private let configuration: MQTTConfiguration
    private let password: String
    private let clientID: String
    private let will: (topic: String, payload: String)?
    private let queue = DispatchQueue(label: "local.logi-easy-switch.mqtt")
    private var connection: NWConnection?
    private var decoder = MQTTPacketDecoder()
    private var packetDeadline: DispatchWorkItem?
    private var handshakeDeadline: DispatchWorkItem?
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
        queue.async { [weak self] in self?.connectOnQueue() }
    }

    private func connectOnQueue() {
        guard configuration.isUsable, let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            onDisconnected?(ClientError.invalidConfiguration)
            return
        }
        guard password.utf8.count <= 4_096, clientID.utf8.count <= 256,
              (will?.topic.utf8.count ?? 0) <= 4_096, (will?.payload.utf8.count ?? 0) <= 4_096 else {
            onDisconnected?(ClientError.invalidConfiguration)
            return
        }
        let tls = NWProtocolTLS.Options()
        if !configuration.tlsServerName.isEmpty {
            // Select the expected certificate identity; Apple's normal chain,
            // expiry, and hostname checks still apply. Never bypass verification.
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, configuration.tlsServerName)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(configuration.host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let timeout = DispatchWorkItem { [weak self] in self?.finish(ClientError.disconnected("MQTT handshake timed out.")) }
                self.handshakeDeadline = timeout
                self.queue.asyncAfter(deadline: .now() + 15, execute: timeout)
                self.sendRaw(self.connectPacket())
                self.receiveNext()
            case .waiting(let error), .failed(let error): self.finish(error)
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
            self.finish(nil)
        }
    }

    func subscribe(_ topic: String) {
        queue.async { [weak self] in
            guard let self, self.isConnected else { return }
            guard !topic.isEmpty, topic.utf8.count <= 4_096 else {
                self.finish(LogiError.protocolError("MQTT topic exceeds the limit."))
                return
            }
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
            guard !topic.isEmpty, topic.utf8.count <= 4_096 else {
                self.finish(LogiError.protocolError("MQTT topic exceeds the limit."))
                return
            }
            var body = Data()
            body.appendMQTTString(topic)
            guard body.count + payload.count <= MQTTPacketDecoder.maximumBodySize else {
                self.finish(LogiError.protocolError("MQTT publication exceeds the limit."))
                return
            }
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
        guard let active = connection else { return }
        active.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak active] data, _, complete, error in
            guard let self, let active, self.connection === active else { return }
            do {
                if let data {
                    let packets = try self.decoder.append(data)
                    for packet in packets {
                        try self.handlePacket(packet)
                        guard self.connection === active else { return }
                    }
                    // Completed packets end the previous assembly deadline;
                    // further fragments cannot extend the next packet's deadline.
                    if !packets.isEmpty || !self.decoder.hasPartialPacket {
                        self.packetDeadline?.cancel()
                        self.packetDeadline = nil
                    }
                    if self.decoder.hasPartialPacket, self.packetDeadline == nil {
                        let timeout = DispatchWorkItem { [weak self] in
                            self?.finish(ClientError.disconnected("MQTT packet assembly timed out."))
                        }
                        self.packetDeadline = timeout
                        self.queue.asyncAfter(deadline: .now() + 15, execute: timeout)
                    }
                }
            } catch { self.finish(error); return }
            if let error { self.finish(error); return }
            if complete { self.finish(nil); return }
            self.receiveNext()
        }
    }

    private func handlePacket(_ packet: MQTTPacket) throws {
        switch packet.header {
        case 0x20:
            let body = [UInt8](packet.body)
            guard !isConnected, body.count == 2, body[0] == 0, body[1] <= 5 else {
                throw LogiError.protocolError("Invalid MQTT CONNACK.")
            }
            guard body[1] == 0 else { throw ClientError.connectionRefused(body[1]) }
            handshakeDeadline?.cancel()
            handshakeDeadline = nil
            isConnected = true
            startKeepAlive()
            onConnected?()
        case 0x30, 0x31:
            guard isConnected else { throw LogiError.protocolError("MQTT publication before CONNACK.") }
            let message = try packet.publication()
            onMessage?(message.topic, message.payload, message.retained)
        case 0x90:
            guard isConnected, packet.body.count >= 3 else { throw LogiError.protocolError("Invalid MQTT SUBACK.") }
        case 0xd0:
            guard isConnected, packet.body.isEmpty else { throw LogiError.protocolError("Invalid MQTT PINGRESP.") }
        default:
            throw LogiError.protocolError("Unexpected MQTT packet.")
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
        packetDeadline?.cancel()
        packetDeadline = nil
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        decoder = MQTTPacketDecoder()
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

private extension Data {
    mutating func appendMQTTString(_ string: String) {
        let bytes = Data(string.utf8)
        append(contentsOf: [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)])
        append(bytes)
    }
}
