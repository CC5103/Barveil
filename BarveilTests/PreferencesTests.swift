import XCTest
@testable import Barveil

@MainActor
final class PreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BarveilTests.Preferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshInstallDoesNotEnableAutomationBeforeOnboarding() {
        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.isEnabled)
        XCTAssertFalse(preferences.hasCompletedOnboarding)
        XCTAssertFalse(preferences.hasRequestedAccessibility)
        XCTAssertEqual(preferences.mode, .smart)
        XCTAssertEqual(preferences.language, .system)
    }

    func testLanguageSelectionPersistsAcrossLaunches() {
        let first = Preferences(defaults: defaults)
        first.language = .japanese

        let second = Preferences(defaults: defaults)

        XCTAssertEqual(second.language, .japanese)
        XCTAssertEqual(second.resolvedLocale.identifier, "ja")
    }

    func testWindowTitleFollowsTheSelectedInAppLanguage() {
        let preferences = Preferences(defaults: defaults)

        preferences.language = .english
        XCTAssertEqual(preferences.localized("Barveil Settings"), "Barveil Settings")

        preferences.language = .simplifiedChinese
        XCTAssertEqual(preferences.localized("Barveil Settings"), "Barveil 设置")

        preferences.language = .japanese
        XCTAssertEqual(preferences.localized("Barveil Settings"), "Barveil 設定")
    }

    func testAccessibilityRequestIsOnlyRememberedOnce() {
        let first = Preferences(defaults: defaults)
        first.hasRequestedAccessibility = true

        let second = Preferences(defaults: defaults)

        XCTAssertTrue(second.hasRequestedAccessibility)
    }

    func testExistingInstallSkipsNewOnboardingAndPreservesChoice() {
        defaults.set(true, forKey: "isEnabled")

        let preferences = Preferences(defaults: defaults)

        XCTAssertTrue(preferences.isEnabled)
        XCTAssertTrue(preferences.hasCompletedOnboarding)
    }

    func testExistingDisabledInstallStaysDisabledWithoutReonboarding() {
        defaults.set(false, forKey: "isEnabled")

        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.isEnabled)
        XCTAssertTrue(preferences.hasCompletedOnboarding)
    }
}
