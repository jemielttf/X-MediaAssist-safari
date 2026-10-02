import XCTest
import ServiceManagement
import XMediaAssistPreferences
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
    func testGIFPreferencePersistsInSharedStoreWithoutChangingDockPreference() async throws {
        let suite = "XMediaAssist.Tests.GIFApp.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GIFPreferences(defaults: defaults)
        let app = AppPreferences(defaults: defaults, loginItem: LoginItemStub(), gifPreferences: store)
        XCTAssertEqual(try app.gifOptions(), .defaults)
        let options = try GIFConversionOptions(message: ["quality": 50, "maximumFrameRate": 25, "scale": 0.5])
        try app.setGIFOptions(options)
        XCTAssertEqual(GIFPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).options, options)
        XCTAssertFalse(app.hidesDockIcon)
    }

    @MainActor
    func testDockPreferencePersistsWithoutChangingLoginRegistration() async throws {
        let suite = "XMediaAssist.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = LoginItemStub()
        let preferences = AppPreferences(defaults: defaults, loginItem: service)
        XCTAssertFalse(preferences.hidesDockIcon)
        XCTAssertTrue(preferences.setHidesDockIcon(true) { hidden in
            XCTAssertTrue(hidden)
            XCTAssertFalse(preferences.hidesDockIcon)
            return true
        })
        let reloaded = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), loginItem: service)
        XCTAssertTrue(reloaded.hidesDockIcon)
        XCTAssertTrue(reloaded.setHidesDockIcon(false) { hidden in
            XCTAssertFalse(hidden)
            XCTAssertTrue(reloaded.hidesDockIcon)
            return true
        })
        XCTAssertFalse(preferences.hidesDockIcon)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
    }

    @MainActor
    func testFailedDockChangeKeepsSavedPreference() async throws {
        let suite = "XMediaAssist.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults, loginItem: LoginItemStub())
        for savedValue in [false, true] {
            preferences.hidesDockIcon = savedValue
            XCTAssertFalse(preferences.setHidesDockIcon(!savedValue) { _ in false })
            XCTAssertEqual(preferences.hidesDockIcon, savedValue)
        }
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
