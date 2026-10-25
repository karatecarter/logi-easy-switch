import Foundation
import SwiftUI

enum DeckLogiScope: String, Codable, CaseIterable {
    case both, keyboard, mouse
    var label: String { switch self { case .both: "Both"; case .keyboard: "Keyboard"; case .mouse: "Mouse" } }
    func includes(_ device: LogiDevice) -> Bool {
        (self == .both && ["KEYBOARD", "MOUSE"].contains(device.type)) ||
        (self == .keyboard && device.type == "KEYBOARD") || (self == .mouse && device.type == "MOUSE")
    }
}

struct DeckLogiRequest: Codable, Equatable {
    var target: String
    var devices: DeckLogiScope = .both
    static func from(_ button: DeckButton) throws -> Self {
        let target = (button.settings["destination"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw DeckError.message("Choose a destination computer.") }
        guard let scope = DeckLogiScope(rawValue: button.settings["devices"] ?? "both") else { throw DeckError.message("Choose Keyboard, Mouse or Both.") }
        return Self(target: target, devices: scope)
    }
    static func accepted(payload: Data, retained: Bool, targets: [String]) -> Self? {
        guard !retained, payload.count <= 1024, let request = try? JSONDecoder().decode(Self.self, from: payload), targets.contains(request.target) else { return nil }
        return request
    }
}

@MainActor final class DeckLogiService: ObservableObject {
    @Published var destinations: [DeckChoice] = []
    var perform: ((DeckLogiRequest) async throws -> Void)?
    func execute(_ request: DeckLogiRequest) async throws {
        guard let perform else { throw DeckError.message("Logitech switching is not available.") }
        try await perform(request)
    }
}

struct DeckLogiProvider: DeckActionProvider {
    let service: DeckLogiService
    let kinds = ["logi"]
    func execute(_ button: DeckButton, configuration: DeckConfiguration) async throws {
        try await service.execute(DeckLogiRequest.from(button))
    }
    func presentation(_ button: DeckButton, configuration: DeckConfiguration) async throws -> DeckPresentation {
        let request = try DeckLogiRequest.from(button)
        let name = await service.destinations.first { $0.id == request.target }?.title ?? request.target
        return DeckPresentation(text: "\(request.devices.label) → \(name)", icon: button.icon == "square.grid.2x2" ? "keyboard" : button.icon)
    }
}

struct DeckLogiEditor: View {
    @Binding var button: DeckButton
    @ObservedObject var service: DeckLogiService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Devices", selection: Binding(get: { button.settings["devices"] ?? "both" }, set: { button.settings["devices"] = $0 })) {
                ForEach(DeckLogiScope.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }.pickerStyle(.menu).fixedSize(horizontal: true, vertical: false)
            DeckSearchPicker(title: "Destination computer", selection: button.settings["destination"] ?? "", choices: service.destinations) { button.settings["destination"] = $0 }
            Text("Uses the default keyboard and mouse from the main Settings window. MQTT can request devices from another Mac; otherwise the selected devices must be connected here.").font(.caption).foregroundStyle(.secondary)
            if service.destinations.isEmpty { Text("Configure devices and remembered computers in the main Settings window first.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
