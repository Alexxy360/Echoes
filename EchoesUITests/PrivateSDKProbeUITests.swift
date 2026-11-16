import XCTest

@MainActor final class PrivateSDKProbeUITests: XCTestCase {
    func testMissingSDKPermitStopsAutorunBeforeNativeSourcesAndOffersNoMutation() {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_PRIVATE_PROFILE_SDK_TEST"] = "1"
        app.launchEnvironment["ECHOES_PRIVATE_PROFILE_SDK_AUTORUN"] = "1"
        app.launch()
        let unavailable = app.descendants(matching: .any).matching(identifier: "profile.sdk.unconfigured")
            .firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["profile.sdk.run"].exists)
        XCTAssertFalse(app.staticTexts["Wynik"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "private-sdk-unconfigured"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
