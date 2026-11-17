import XCTest

/// Real views/host/cache/ImageIO, synthetic identity and photo/community API only.
@MainActor final class GatewayAvatarUITests: XCTestCase {
    private let peerA = "11111111-1111-4111-8111-111111111111"
    private let peerB = "22222222-2222-4222-8222-222222222222"
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func application(_ mode: String = "avatars", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_COMMUNITY_UI_PREVIEW"] = mode
        if large {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        XCTAssertTrue(element(app, "community.preview.banner").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["map.profile." + peerB].waitForExistence(timeout: 15))
        return app
    }
    private func profile(_ app: XCUIApplication, peer: String? = nil) -> XCUIElement {
        let button = app.buttons["map.profile." + (peer ?? peerB)]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let avatar = element(app, "community.avatar.profile")
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        return avatar
    }
    private func loaded(_ avatar: XCUIElement, app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Wczytane"), object: avatar)
        let result = XCTWaiter.wait(for: [expectation], timeout: 12)
        if result != .completed { print(String(app.debugDescription.prefix(6000))) }
        XCTAssertEqual(result, .completed)
    }
    private func action(_ app: XCUIApplication, _ title: String) {
        app.buttons["community.preview.actions"].tap()
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
    func testAvatarProfileAndChatRenderTheProtectedPresentation() {
        let app = application()
        let map = element(app, "community.avatar.map")
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        loaded(map, app: app)
        attach(app, "avatar-map-loaded")
        let avatar = profile(app)
        loaded(avatar, app: app)
        attach(app, "avatar-profile-loaded-A")
        app.buttons["Zamknij"].tap()
        app.buttons["Czat w okolicy"].tap()
        XCTAssertTrue(app.staticTexts["Zdjęcie w czacie"].waitForExistence(timeout: 10))
        let message = element(app, "community.avatar.message")
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        loaded(message, app: app)
        attach(app, "avatar-chat-loaded")
    }
    func testAvatarDenialShowsInitialAndExplicitRetry() {
        let app = application("avatars-denied")
        let avatar = profile(app)
        XCTAssertTrue(app.buttons["community.avatar.retry"].waitForExistence(timeout: 10))
        XCTAssertEqual(avatar.value as? String, "Inicjał")
        attach(app, "avatar-profile-denied")
    }
    func testAvatarCorruptFileNeverRendersAndExplicitRetryRecovers() {
        let app = application("avatars-corrupt")
        let avatar = profile(app)
        let retry = app.buttons["community.avatar.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertEqual(avatar.value as? String, "Inicjał")
        attach(app, "avatar-corrupt-initial")
        retry.tap()
        loaded(avatar, app: app)
        attach(app, "avatar-corrupt-recovered")
    }
    func testAvatarDelayedReplyCannotRestoreWithdrawnPhoto() {
        let app = application("avatars-delayed")
        _ = profile(app)
        XCTAssertTrue(element(app, "community.avatar.loading").waitForExistence(timeout: 10))
        app.buttons["Zamknij"].tap()
        action(app, "Ukryj zdjęcie testowe")
        action(app, "Zwolnij odczyty zdjęć")
        let avatar = profile(app)
        XCTAssertEqual(avatar.value as? String, "Inicjał")
        XCTAssertFalse(app.buttons["community.avatar.retry"].exists)
        XCTAssertFalse(element(app, "community.avatar.loading").exists)
        attach(app, "avatar-withdrawn-after-late-reply")
    }
    func testAvatarAccountChangeAndBackgroundCloseOldPresentation() {
        let app = application()
        loaded(profile(app), app: app)
        app.buttons["Zamknij"].tap()
        action(app, "Zmień konto testowe")
        XCTAssertTrue(app.buttons["map.profile." + peerA].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["map.profile." + peerB].exists)
        loaded(profile(app, peer: peerA), app: app)
        attach(app, "avatar-profile-loaded-B")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element(app, "community.preview.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "community.avatar.profile").exists)
        attach(app, "avatar-background-closed")
    }
    func testAvatarProfileSupportsLargestTextAndBlocking() {
        let app = application(large: true)
        loaded(profile(app), app: app)
        let block = app.buttons["Zablokuj użytkownika"]
        for _ in 0..<7 where !block.isHittable { app.swipeUp() }
        XCTAssertTrue(block.isHittable)
        attach(app, "avatar-profile-accessibility-text")
        block.tap()
        XCTAssertTrue(app.buttons["map.profile." + peerB].waitForNonExistence(timeout: 10))
        XCTAssertFalse(element(app, "community.avatar.profile").exists)
    }
    func testAvatarExpiryRequiresFreshReadBeforePixelsReturn() {
        let app = application()
        let avatar = profile(app)
        loaded(avatar, app: app)
        let expired = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Inicjał"), object: avatar)
        XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 36), .completed)
        let retry = app.buttons["community.avatar.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        attach(app, "avatar-expired-initial")
        retry.tap()
        loaded(avatar, app: app)
        attach(app, "avatar-expired-revalidated")
    }

}
