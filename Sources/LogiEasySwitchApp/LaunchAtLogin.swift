import ServiceManagement

enum LaunchAtLogin {
    static var isRegistered: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if !isRegistered { try SMAppService.mainApp.register() }
        } else if isRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
