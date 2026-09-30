// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class AppPreferences {
    private let defaults: UserDefaults
    private let loginItem: any LoginItemService

    init(defaults: UserDefaults = .standard, loginItem: any LoginItemService = SMAppService.mainApp) {
        self.defaults = defaults
        self.loginItem = loginItem
    }

    var hidesDockIcon: Bool {
        get { defaults.bool(forKey: "hidesDockIcon") }
        set { defaults.set(newValue, forKey: "hidesDockIcon") }
    }

    func setHidesDockIcon(_ hidden: Bool, applying apply: (Bool) -> Bool) -> Bool {
        guard apply(hidden) else { return false }
        hidesDockIcon = hidden
        return true
    }

    // macOS is the source of truth, including changes made in System Settings.
    var loginItemStatus: SMAppService.Status { loginItem.status }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        switch (enabled, loginItem.status) {
        case (true, .enabled), (true, .requiresApproval), (false, .notRegistered), (false, .notFound):
            return
        case (true, _):
            try loginItem.register()
        case (false, _):
            try loginItem.unregister()
        }
    }
}
