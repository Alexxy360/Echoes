import XCTest

/// Actual app Security, random synthetic scopes only. No native account or provider requests.
@MainActor final class GatewayAvatarReportReviewJournalStorageUITests: XCTestCase {
    func testReportedPhotoModeratorAppKeychainTargetRecoveryRetirementAndExactOwnerCleanup() {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_STORAGE_CHECK"] = "1"
        app.launchEnvironment["ECHOES_GATEWAY_REPORTED_PHOTO_STORAGE_CHECK"] = "1"
        app.launch()
        let result = app.staticTexts["gateway.storage.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertEqual(result.label, "passed")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "reported-photo-moderator-app-keychain-passed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    func testAggregatePropagatesReportedPhotoStorageFailureAfterSyntheticCleanup() {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_STORAGE_CHECK"] = "1"
        app.launchEnvironment["ECHOES_GATEWAY_REPORTED_PHOTO_STORAGE_FAULT"] = "1"
        app.launch()
        let result = app.staticTexts["gateway.storage.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertEqual(result.label, "injected-bound-failed")
    }
}
