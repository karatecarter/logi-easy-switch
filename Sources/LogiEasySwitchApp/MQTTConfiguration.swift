import Foundation
import Security

struct MQTTConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var host = ""
    var port = 8883
    var useTLS = true
    var tlsServerName = ""
    var username = ""
    var computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac"
    var discoveryEnabled = true

    var topicPrefix = "logi-easy-switch"

    var validationMessage: String? {
        if !useTLS { return "MQTT requires TLS. Enable TLS and use your broker’s TLS port (usually 8883)." }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(1...65535).contains(port) {
            return "Enter a broker address and a valid port."
        }
        if host.utf8.count > 1_024 || username.utf8.count > 4_096 || computerName.utf8.count > 1_024 {
            return "MQTT settings exceed the supported length."
        }
        if !tlsServerName.isEmpty {
            let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
            let labels = tlsServerName.split(separator: ".", omittingEmptySubsequences: false)
            if tlsServerName.utf8.count > 253 || tlsServerName.unicodeScalars.contains(where: { !nameCharacters.contains($0) }) ||
                labels.contains(where: { $0.isEmpty || $0.utf8.count > 63 || $0.hasPrefix("-") || $0.hasSuffix("-") }) {
                return "Enter the DNS hostname on your broker certificate, without a port or URL."
            }
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        if topicPrefix.isEmpty || topicPrefix.utf8.count > 64 || topicPrefix.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "MQTT namespace must be 1–64 letters, digits, hyphens, or underscores."
        }
        return nil
    }

    var isUsable: Bool { enabled && validationMessage == nil }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, host, port, useTLS, tlsServerName, username, computerName, discoveryEnabled, topicPrefix
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? host
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? port
        useTLS = try values.decodeIfPresent(Bool.self, forKey: .useTLS) ?? useTLS
        tlsServerName = try values.decodeIfPresent(String.self, forKey: .tlsServerName) ?? tlsServerName
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? username
        computerName = try values.decodeIfPresent(String.self, forKey: .computerName) ?? computerName
        discoveryEnabled = try values.decodeIfPresent(Bool.self, forKey: .discoveryEnabled) ?? discoveryEnabled
        topicPrefix = try values.decodeIfPresent(String.self, forKey: .topicPrefix) ?? topicPrefix
    }
}

enum MQTTPasswordStore {
    private static let service = "local.logi-easy-switch.mqtt"
    private static let account = "broker-password"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ password: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status: OSStatus
        if password.isEmpty {
            status = SecItemDelete(key as CFDictionary)
        } else {
            let attributes = [kSecValueData as String: Data(password.utf8)]
            let updated = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
            if updated == errSecItemNotFound {
                var item = key
                item[kSecValueData as String] = Data(password.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else {
                status = updated
            }
        }
        guard status == errSecSuccess || (password.isEmpty && status == errSecItemNotFound) else {
            throw LogiError.requestFailed("Could not save MQTT password to Keychain (status \(status)).")
        }
    }

}
