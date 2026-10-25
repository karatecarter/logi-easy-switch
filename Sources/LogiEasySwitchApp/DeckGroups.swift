import Foundation

// Child actions are ordinary buttons owned by a group, preserving existing provider settings.
enum DeckGroups {
    static func controls(_ group: DeckButton, in configuration: DeckConfiguration) -> [DeckButton] {
        configuration.buttons.filter { $0.parentID == group.id }
    }
    static func activationTargets(in folder: UUID?, configuration: DeckConfiguration) -> [DeckButton] {
        configuration.buttons.filter { $0.parentID == folder }.flatMap { button in
            button.kind == "group" ? controls(button, in: configuration) : [button]
        }
    }
    static func containingFolder(of button: DeckButton, configuration: DeckConfiguration) -> UUID? {
        let owner = configuration.buttons.first { $0.id == button.parentID }
        return owner?.kind == "group" ? owner?.parentID : button.parentID
    }
    static func returnDestination(for button: DeckButton, configuration: DeckConfiguration) -> UUID? {
        let parent = containingFolder(of: button, configuration: configuration).flatMap { backDestination(from: $0, configuration: configuration) }
        guard let rule = button.returnAfterAction, !rule.useParent else { return parent }
        guard let target = rule.folderID else { return nil }
        return configuration.buttons.contains { $0.id == target && $0.kind == "folder" } ? target : parent
    }
    static func folderLabel(_ folder: DeckButton, configuration: DeckConfiguration) -> String {
        var names = [folder.name]
        var parent = folder.parentID
        var visited: Set<UUID> = [folder.id]
        while let id = parent, visited.insert(id).inserted, let owner = configuration.buttons.first(where: { $0.id == id }) {
            names.insert(owner.name, at: 0)
            parent = owner.parentID
        }
        return names.joined(separator: " / ")
    }
    static func keyPeers(for button: DeckButton, configuration: DeckConfiguration) -> [DeckButton] {
        let owner = configuration.buttons.first { $0.id == button.parentID }
        let folder = owner?.kind == "group" ? owner?.parentID : button.parentID
        return activationTargets(in: folder, configuration: configuration)
    }
    static func backDestination(from folder: UUID, configuration: DeckConfiguration) -> UUID? {
        var parent = configuration.buttons.first { $0.id == folder }?.parentID
        var visited: Set<UUID> = [folder]
        while let id = parent, let owner = configuration.buttons.first(where: { $0.id == id }), owner.kind == "group" {
            guard visited.insert(id).inserted else { return nil }
            parent = owner.parentID
        }
        return parent
    }
}

enum DeckThermostatPreset {
    static func make(parentID: UUID? = nil) -> [DeckButton] {
        var group = DeckButton()
        group.name = "Thermostat"
        group.kind = "group"
        group.icon = "thermometer"
        group.parentID = parentID
        group.settings = ["preset": "thermostat", "textReplacesName": "true"]
        var increase = DeckButton()
        increase.name = "+"
        increase.kind = "homeassistant"
        increase.parentID = group.id
        increase.dismiss = .never
        increase.settings = ["action": "script.adjust_thermostat", "data": "{\"incr\":1}", "thermostatRole": "increase"]
        var decrease = increase
        decrease.id = UUID()
        decrease.name = "−"
        decrease.settings["data"] = "{\"incr\":-1}"
        decrease.settings["thermostatRole"] = "decrease"
        var mode = DeckButton()
        mode.name = "Mode"
        mode.kind = "folder"
        mode.parentID = group.id
        let modes = ["cool", "heat", "auto", "off"].map { value -> DeckButton in
            var button = DeckButton()
            button.name = value.capitalized
            button.kind = "homeassistant"
            button.parentID = mode.id
            button.settings = ["action": "climate.set_hvac_mode", "data": "{\"hvac_mode\":\"\(value)\"}", "thermostatRole": "mode", "requiresThermostat": "true"]
            return button
        }
        return [group, increase, decrease, mode] + modes
    }

    static func configure(groupID: UUID, entity: String? = nil, script: String? = nil, configuration: inout DeckConfiguration) throws {
        guard let index = configuration.buttons.firstIndex(where: { $0.id == groupID }) else { return }
        let controls = DeckGroups.controls(configuration.buttons[index], in: configuration)
        let modeFolders = Set(controls.filter { $0.kind == "folder" }.map(\.id))
        if let entity {
            guard entity.hasPrefix("climate."), entity.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) else { throw DeckError.message("Choose a climate entity.") }
            configuration.buttons[index].settings["climateEntity"] = entity
            configuration.buttons[index].settings["textTemplate"] = template(entity: entity)
            for child in configuration.buttons.indices where configuration.buttons[child].parentID.map({ modeFolders.contains($0) }) == true && configuration.buttons[child].settings["thermostatRole"] == "mode" {
                configuration.buttons[child].settings["data"] = try DeckHATarget.selecting(entity, in: configuration.buttons[child].settings["data"] ?? "{}")
                configuration.buttons[child].settings.removeValue(forKey: "requiresThermostat")
            }
        }
        if let script {
            configuration.buttons[index].settings["adjustScript"] = script
            for child in configuration.buttons.indices where configuration.buttons[child].parentID == groupID && ["increase", "decrease"].contains(configuration.buttons[child].settings["thermostatRole"] ?? "") {
                configuration.buttons[child].settings["action"] = script
            }
        }
    }

    static func template(entity: String) -> String {
        """
        {% set current = state_attr('\(entity)', 'current_temperature') %}{% set target = state_attr('\(entity)', 'temperature') %}{% set low = state_attr('\(entity)', 'target_temp_low') %}{% set high = state_attr('\(entity)', 'target_temp_high') %}Thermostat - {{ current if current is not none else '—' }}
        {{ states('\(entity)') | replace('_', ' ') | title }} set to {{ target if target is not none else ((low | string) ~ '–' ~ (high | string) if low is not none and high is not none else '—') }}
        """
    }
}
