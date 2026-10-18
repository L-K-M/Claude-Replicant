import ServiceManagement

/// Opening Claude Replicant at login, through the system's Login Items
/// (System Settings → General → Login Items).
enum LoginItem {
    enum Status {
        case off
        case on
        /// Registered, but the user has to allow it in System Settings.
        case needsApproval
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
