import Foundation
import Security

struct DeckButton: Codable, Identifiable, Equatable {
    var id = UUID()
    var parentID: UUID?
    var name = "New shortcut"
    var key: Shortcut?
    var icon = "square.grid.2x2"
    var kind = "application"
    var settings: [String: String] = [:]
    var dismiss = DeckDismiss.inherit
    var delay: Double = 0
    var returnAfterAction: DeckReturnBehavior?
}

struct DeckReturnBehavior: Codable, Equatable {
    var enabled = false
    var useParent = true
    var folderID: UUID?
    var delay: Double = 0
}

enum DeckDismiss: String, Codable, CaseIterable {
    case inherit = "Default", always = "Always", never = "Never"
    func delay(defaultEnabled: Bool, defaultDelay: Double, override: Double) -> Double? {
        switch self {
        case .inherit: return defaultEnabled ? Self.safeDelay(defaultDelay) : nil
        case .always: return Self.safeDelay(override)
        case .never: return nil
        }
    }
    private static func safeDelay(_ value: Double) -> Double { value.isFinite ? min(86400, max(0, value)) : 0 }
}

struct DeckConfiguration: Codable, Equatable {
    var hotkey: Shortcut?
    var dismissAfterAction = true
    var actionDelay: Double = 0
    var idleTimeout: Double = 0
    // Nil preserves the legacy convention: a positive timeout enables dismissal.
    var dismissAfterOpening: Bool?
    var openingDismissEnabled: Bool {
        get { dismissAfterOpening ?? (idleTimeout > 0) }
        set { dismissAfterOpening = newValue }
    }
    var homeAssistantURL = ""
    var buttons: [DeckButton] = []
}

@MainActor final class DeckStore: ObservableObject {
    @Published var configuration: DeckConfiguration { didSet { save() } }
    @Published var hotkeyError: String?
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (try? JSONDecoder().decode(DeckConfiguration.self, from: defaults.data(forKey: "shortcutDeck.v1") ?? Data())) ?? DeckConfiguration()
        configuration = saved.migratingThermostatTicks()
        if configuration != saved { save() }
    }
    private func save() {
        defaults.set(try? JSONEncoder().encode(configuration), forKey: "shortcutDeck.v1")
        onChange?()
    }
}

enum DeckTokenStore {
    private static let cache = CredentialSessionCache()
    static func load(retry: Bool = false) -> String {
        cache.load(retry: retry) {
            var result: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.logi-easy-switch.deck", kSecAttrAccount as String: "ha-token", kSecReturnData as String: true]
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return "" }
            guard status == errSecSuccess, let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func save(_ token: String) throws {
        try cache.save(token) {
            let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.logi-easy-switch.deck", kSecAttrAccount as String: "ha-token"]
            var status: OSStatus
            if token.isEmpty { status = SecItemDelete(key as CFDictionary) }
            else {
                status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
                if status == errSecItemNotFound {
                    var item = key
                    item[kSecValueData as String] = Data(token.utf8)
                    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    status = SecItemAdd(item as CFDictionary, nil)
                }
            }
            guard status == errSecSuccess || (token.isEmpty && status == errSecItemNotFound) else { throw DeckError.message("Keychain error: \(status)") }
        }
    }
}

enum DeckError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

struct DeckPresentation: Equatable {
    var text: String = ""
    var icon: String?
    var highlighted: Bool?
    var pendingSetpoint = false
}

// Providers own execution and presentation, independent of the launcher and editor.
protocol DeckActionProvider {
    var kinds: [String] { get }
    func execute(_ button: DeckButton, configuration: DeckConfiguration) async throws
    func presentation(_ button: DeckButton, configuration: DeckConfiguration) async throws -> DeckPresentation
}
