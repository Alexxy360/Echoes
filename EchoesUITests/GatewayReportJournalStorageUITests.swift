import XCTest

/// Actual app Keychain; random synthetic owners. No provider, account, Firebase or HTTP traffic.
@MainActor final class GatewayReportJournalStorageUITests: XCTestCase {
    func testAppKeychainReportDecisionRoundTripRecoveryAndExactOwnerCleanup() {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_STORAGE_CHECK"] = "1"
        app.launch()
        let result = app.staticTexts["gateway.storage.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertEqual(result.label, "passed")
        XCTAssertTrue(app.staticTexts["Kontrola zaliczona"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "report-journal-app-keychain-passed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
