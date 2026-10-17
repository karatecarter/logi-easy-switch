import Foundation
import Security

struct MQTTConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var host = ""
    var port = 1883
    var useTLS = false
    var username = ""
    var computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac"
    var discoveryEnabled = true

    var isUsable: Bool { enabled && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...65535).contains(port) }
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

    static func save(_ password: String) {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(key as CFDictionary)
        guard !password.isEmpty else { return }
        var item = key
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
