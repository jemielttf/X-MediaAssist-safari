import XCTest
import ServiceManagement
@testable import XMediaAssistAppSupport

@MainActor
private final class LoginItemStub: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var failure: Error?
    var registrations = 0
    var unregistrations = 0

    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = registrationStatus
    }

    func unregister() throws {
        unregistrations += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}

final class AppPreferencesTests: XCTestCase {
    @MainActor
    func testDockPreferencePersistsWithoutChangingLoginRegistration() async throws {
        let suite = "XMediaAssist.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = LoginItemStub()
        let preferences = AppPreferences(defaults: defaults, loginItem: service)
        XCTAssertFalse(preferences.hidesDockIcon)
        preferences.hidesDockIcon = true
        let reloaded = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), loginItem: service)
        XCTAssertTrue(reloaded.hidesDockIcon)
        reloaded.hidesDockIcon = false
        XCTAssertFalse(preferences.hidesDockIcon)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
    }

    @MainActor
    func testLoginRegistrationUsesSystemStateAndAvoidsDuplicateRequests() async throws {
        let service = LoginItemStub()
        let preferences = AppPreferences(loginItem: service)
        try preferences.setLaunchAtLogin(true)
        XCTAssertEqual(preferences.loginItemStatus, .enabled)
        try preferences.setLaunchAtLogin(true)
        XCTAssertEqual(service.registrations, 1)
        // Reflect changes made outside the app without cached preferences.
        service.status = .requiresApproval
        XCTAssertEqual(preferences.loginItemStatus, .requiresApproval)
        try preferences.setLaunchAtLogin(true)
        XCTAssertEqual(service.registrations, 1)
        try preferences.setLaunchAtLogin(false)
        XCTAssertEqual(preferences.loginItemStatus, .notRegistered)
        try preferences.setLaunchAtLogin(false)
        XCTAssertEqual(service.unregistrations, 1)
    }

    @MainActor
    func testPendingApprovalIsNotReportedAsEnabled() async throws {
        let service = LoginItemStub()
        service.registrationStatus = .requiresApproval
        let preferences = AppPreferences(loginItem: service)
        try preferences.setLaunchAtLogin(true)
        XCTAssertEqual(preferences.loginItemStatus, .requiresApproval)
        try preferences.setLaunchAtLogin(false)
        XCTAssertEqual(service.unregistrations, 1)
    }

    @MainActor
    func testServiceFailuresDoNotChangeReportedState() async throws {
        let service = LoginItemStub()
        service.failure = NSError(domain: "Test", code: 1)
        let preferences = AppPreferences(loginItem: service)
        XCTAssertThrowsError(try preferences.setLaunchAtLogin(true))
        XCTAssertEqual(preferences.loginItemStatus, .notRegistered)
        service.status = .enabled
        XCTAssertThrowsError(try preferences.setLaunchAtLogin(false))
        XCTAssertEqual(preferences.loginItemStatus, .enabled)
    }
}
