import XCTest

/// Actual app Keychain; random synthetic owners. No provider, account, Firebase or HTTP traffic.
@MainActor final class GatewayAvatarReportJournalStorageUITests: XCTestCase {
    func testAppKeychainPhotoReportRecoveryCapacityAndExactOwnerCleanup() {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_STORAGE_CHECK"] = "1"
        app.launch()
        let result = app.staticTexts["gateway.storage.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertEqual(result.label, "passed")
        XCTAssertTrue(app.staticTexts["Kontrola zaliczona"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "avatar-report-journal-app-keychain-passed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    func testAppKeychainPhotoReportSurvivesProcessTerminationThenRecoversOriginalAttempt() {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_STORAGE_CHECK"] = "1"
        app.launchEnvironment["ECHOES_PHOTO_REPORT_RESTART_ID"] = UUID().uuidString.lowercased()
        defer {
            app.terminate()
            app.launchEnvironment["ECHOES_PHOTO_REPORT_RESTART_PHASE"] = "cleanup"
            app.launch()
            let cleanup = app.staticTexts["gateway.storage.result"]
            XCTAssertTrue(cleanup.waitForExistence(timeout: 20))
            XCTAssertEqual(cleanup.label, "passed")
            app.terminate()
        }
        app.launchEnvironment["ECHOES_PHOTO_REPORT_RESTART_PHASE"] = "prepare"
        app.launch()
        let prepared = app.staticTexts["gateway.storage.result"]
        XCTAssertTrue(prepared.waitForExistence(timeout: 20))
        XCTAssertEqual(prepared.label, "passed")
        app.terminate()
        app.launchEnvironment["ECHOES_PHOTO_REPORT_RESTART_PHASE"] = "recover"
        app.launch()
        let recovered = app.staticTexts["gateway.storage.result"]
        XCTAssertTrue(recovered.waitForExistence(timeout: 20))
        XCTAssertEqual(recovered.label, "passed")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "avatar-report-journal-process-restart-passed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
