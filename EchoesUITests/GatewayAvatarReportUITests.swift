import XCTest

/// Actual profile/form/protected-image host/journal/HTTPClient; provider and identity synthetic.
@MainActor final class GatewayAvatarReportUITests: XCTestCase {
    private func item(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private enum FlowError: Error { case missing(String) }
    private func app(_ mode: String = "avatar-report", large: Bool = false) -> XCUIApplication {
        let value = XCUIApplication()
        value.launchEnvironment["ECHOES_GATEWAY_COMMUNITY_UI_PREVIEW"] = mode
        value.launchEnvironment["ECHOES_AVATAR_REPORT_UI_RUN_ID"] = UUID().uuidString.lowercased()
        value.launchArguments = []
        if large {
            value.launchArguments = [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        value.launch()
        XCTAssertTrue(item(value, "community.preview.banner").waitForExistence(timeout: 15))
        return value
    }
    private func scroll(_ app: XCUIApplication, up: Bool) {
        let confirmation = item(app, "avatar.report.confirmationContent")
        let form = item(app, "avatar.report.form")
        let target = confirmation.exists ? confirmation : (form.exists ? form : app)
        if up { target.swipeUp() } else { target.swipeDown() }
    }
    @discardableResult private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let element = item(app, id)
        for _ in 0..<9 {
            if element.exists, element.frame.minY >= 150, element.frame.maxY <= app.frame.maxY - 20 {
                return element
            }
            scroll(app, up: !element.exists || element.frame.midY > app.frame.midY)
        }
        return element
    }
    private func tap(_ app: XCUIApplication, _ id: String) throws {
        let button = app.buttons[id]
        for _ in 0..<6 where !button.isHittable { scroll(app, up: true) }
        guard button.exists, button.isHittable, button.isEnabled else {
            XCTFail("Przycisk niedostępny: " + id)
            throw FlowError.missing(id)
        }
        button.tap()
    }
    private func open(_ app: XCUIApplication) throws {
        let profile = app.buttons["map.profile.22222222-2222-4222-8222-222222222222"]
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        profile.tap()
        let button = app.buttons["avatar.report.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        XCTAssertTrue(item(app, "avatar.report.form").waitForExistence(timeout: 12))
        XCTAssertTrue(
            item(app, "avatar.report.photo").waitForExistence(timeout: 12),
            String(app.debugDescription.prefix(6500)))
        let displayed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Zdjęcie zostało wyświetlone."),
            object: item(app, "avatar.report.displayStatus"))
        guard XCTWaiter.wait(for: [displayed], timeout: 8) == .completed else {
            XCTFail("Podgląd nie otrzymał potwierdzenia widoczności")
            throw FlowError.missing("avatar.report.displayStatus")
        }
    }
    private func enter(_ app: XCUIApplication) throws {
        let field = reveal(app, "avatar.report.reason")
        guard field.exists, field.isHittable else {
            XCTFail("Pole powodu nie jest dostępne po przewinięciu")
            throw FlowError.missing("avatar.report.reason")
        }
        field.tap()
        field.typeText("Nieodpowiednie zdjęcie")
        if app.buttons["avatar.report.keyboard.hide"].exists {
            app.buttons["avatar.report.keyboard.hide"].tap()
        }
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot())
        value.name = name
        value.lifetime = .keepAlways
        add(value)
    }
    private func cleanup(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(item(app, "community.preview.banner").waitForExistence(timeout: 15))
        app.buttons["community.preview.actions"].tap()
        let button = app.buttons["avatar.report.preview.cleanup"]
        guard button.waitForExistence(timeout: 5), button.isHittable else {
            XCTFail("Nie można otworzyć sprzątania danych testowych")
            app.terminate()
            return
        }
        button.tap()
        XCTAssertTrue(item(app, "avatar.report.preview.cleaned").waitForExistence(timeout: 5))
        app.terminate()
    }
    func testActualProfilePhotoRequiresReasonAndConfirmationBeforeOneSubmissionAndAck() throws {
        let value = app()
        defer { cleanup(value) }
        try open(value)
        XCTAssertFalse(value.buttons["avatar.report.next"].isEnabled)
        try enter(value)
        try tap(value, "avatar.report.next")
        XCTAssertTrue(value.staticTexts["avatar.report.confirmation.reason"].waitForExistence(timeout: 5))
        attach(value, "photo-report-explicit-confirmation")
        try tap(value, "avatar.report.back")
        XCTAssertEqual(item(value, "avatar.report.reason").value as? String, "Nieodpowiednie zdjęcie")
        try tap(value, "avatar.report.next")
        try tap(value, "avatar.report.confirm")
        XCTAssertTrue(
            item(value, "avatar.report.resolved").waitForExistence(timeout: 10),
            String(value.debugDescription.prefix(6500)))
        attach(value, "photo-report-accepted")
        try tap(value, "avatar.report.ack")
        XCTAssertFalse(item(value, "avatar.report.pending").exists)
    }
    private func restart(_ value: XCUIApplication) {
        value.terminate()
        value.launch()
        XCTAssertTrue(item(value, "community.preview.banner").waitForExistence(timeout: 15))
    }
    private func openRecovery(_ value: XCUIApplication) throws {
        value.buttons["Ustawienia"].tap()
        try tap(value, "settings.avatarReport")
        XCTAssertTrue(item(value, "avatar.report.form").waitForExistence(timeout: 10))
    }
    private func submit(_ value: XCUIApplication) throws {
        try enter(value)
        try tap(value, "avatar.report.next")
        try tap(value, "avatar.report.confirm")
    }
    private func returnToMap(_ value: XCUIApplication) throws {
        value.navigationBars["Zgłoś zdjęcie"].buttons["Zamknij"].tap()
        value.navigationBars["Ustawienia"].buttons["Gotowe"].tap()
        XCTAssertTrue(item(value, "community.preview.banner").waitForExistence(timeout: 5))
    }
    func testLostSubmissionACKRestartsAndRecoversFromSettingsWithoutNewPhotoOrSecondSubmission() throws {
        let value = app("avatar-report-lost")
        defer { cleanup(value) }
        try open(value)
        try submit(value)
        XCTAssertTrue(item(value, "avatar.report.error").waitForExistence(timeout: 10))
        restart(value)
        try openRecovery(value)
        XCTAssertTrue(item(value, "avatar.report.pending").waitForExistence(timeout: 10))
        XCTAssertFalse(item(value, "avatar.report.reason").exists)
        XCTAssertFalse(item(value, "avatar.report.photo").exists)
        try tap(value, "avatar.report.recover")
        XCTAssertTrue(item(value, "avatar.report.resolved").waitForExistence(timeout: 10))
        attach(value, "photo-report-recovered-after-process-restart")
        try tap(value, "avatar.report.ack")
        XCTAssertTrue(item(value, "avatar.report.empty").waitForExistence(timeout: 5))
        try returnToMap(value)
        XCTAssertEqual(item(value, "avatar.report.preview.submits").label, "Wysyłki: 1")
    }
    func testLostCancellationACKRestartsAsCancellingAndReadOnlyRecoveryConfirmsSameFence() throws {
        let value = app("avatar-report-cancel-lost")
        defer { cleanup(value) }
        try open(value)
        try submit(value)
        XCTAssertTrue(item(value, "avatar.report.error").waitForExistence(timeout: 10))
        try tap(value, "avatar.report.reconnect")
        try tap(value, "avatar.report.cancel")
        try tap(value, "avatar.report.confirmCancel")
        XCTAssertTrue(item(value, "avatar.report.error").waitForExistence(timeout: 10))
        restart(value)
        try openRecovery(value)
        let pending = item(value, "avatar.report.pending")
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        XCTAssertTrue(pending.label.contains("Anulowanie"))
        XCTAssertFalse(value.buttons["avatar.report.ack"].exists)
        try tap(value, "avatar.report.recover")
        let result = item(value, "avatar.report.resolved")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "Próba została anulowana.")
        attach(value, "photo-report-cancelled-after-process-restart")
        try tap(value, "avatar.report.ack")
        try returnToMap(value)
        XCTAssertEqual(item(value, "avatar.report.preview.submits").label, "Wysyłki: 1")
        XCTAssertEqual(item(value, "avatar.report.preview.cancels").label, "Anulowania: 1")
    }
    func testUnknownResultStaysPendingUntilUserExplicitlyConfirmsCancellation() throws {
        let value = app("avatar-report-unknown")
        defer { cleanup(value) }
        try open(value)
        try submit(value)
        XCTAssertTrue(item(value, "avatar.report.error").waitForExistence(timeout: 10))
        try tap(value, "avatar.report.reconnect")
        try tap(value, "avatar.report.recover")
        XCTAssertTrue(item(value, "avatar.report.pending").waitForExistence(timeout: 10))
        XCTAssertFalse(value.buttons["avatar.report.ack"].exists)
        try tap(value, "avatar.report.cancel")
        attach(value, "photo-report-explicit-cancellation")
        try tap(value, "avatar.report.back")
        XCTAssertTrue(item(value, "avatar.report.pending").exists)
        try tap(value, "avatar.report.cancel")
        try tap(value, "avatar.report.confirmCancel")
        let result = item(value, "avatar.report.resolved")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "Próba została anulowana.")
    }
    func testExpiredPhotoPreservesReasonAndExplicitFreshReadRequiresNewDisplayBeforeConfirmation() throws {
        let value = app()
        defer { cleanup(value) }
        try open(value)
        try enter(value)
        value.swipeDown()
        XCTAssertTrue(item(value, "avatar.report.expired").waitForExistence(timeout: 36))
        XCTAssertEqual(item(value, "avatar.report.reason").value as? String, "Nieodpowiednie zdjęcie")
        XCTAssertFalse(value.buttons["avatar.report.next"].isEnabled)
        try tap(value, "avatar.report.refresh")
        XCTAssertTrue(item(value, "avatar.report.photo").waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: value.buttons["avatar.report.next"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        XCTAssertEqual(item(value, "avatar.report.reason").value as? String, "Nieodpowiednie zdjęcie")
        attach(value, "photo-report-draft-after-fresh-protected-read")
        try tap(value, "avatar.report.next")
        XCTAssertTrue(item(value, "avatar.report.confirmation.reason").waitForExistence(timeout: 5))
    }
    func testLargestAccessibilityTextCanReachExplicitConfirmationAndCloseWithoutSubmitting() throws {
        let value = app(large: true)
        defer { cleanup(value) }
        try open(value)
        try enter(value)
        try tap(value, "avatar.report.next")
        XCTAssertTrue(reveal(value, "avatar.report.confirmation.reason").exists)
        attach(value, "photo-report-largest-accessibility-text")
        try tap(value, "avatar.report.back")
        XCTAssertEqual(item(value, "avatar.report.reason").value as? String, "Nieodpowiednie zdjęcie")
    }
    func testBackgroundRemovesPhotoReasonAndConfirmationFromOldDomain() throws {
        let value = app()
        defer { cleanup(value) }
        try open(value)
        try enter(value)
        try tap(value, "avatar.report.next")
        XCTAssertTrue(item(value, "avatar.report.confirmation.reason").waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        value.activate()
        XCTAssertTrue(item(value, "community.preview.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(item(value, "avatar.report.photo").exists)
        XCTAssertFalse(item(value, "avatar.report.reason").exists)
        XCTAssertFalse(value.buttons["avatar.report.confirm"].exists)
    }

}
