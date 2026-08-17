import Foundation

struct LogiDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let state: String
    let connected: Bool

    var isAvailable: Bool {
        connected || ["ACTIVE", "PRESENT"].contains(state)
    }
}

struct LogiHost: Identifiable, Hashable, Sendable {
    let index: Int
    let name: String
    let paired: Bool
    let connected: Bool

    var id: Int { index }
}

enum LogiError: LocalizedError {
    case unavailable(String)
    case protocolError(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .protocolError(let message), .requestFailed(let message): message
        }
    }
}
