import XCTest

/// Real editor/file preparation/journal/controller; synthetic identity and backend only.
@MainActor final class GatewayAvatarEditorUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func application(_ mode: String = "avatar-owner", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_COMMUNITY_UI_PREVIEW"] = mode
        if large {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        XCTAssertTrue(element(app, "community.preview.banner").waitForExistence(timeout: 15))
        return app
    }
    private func visibleButton(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let button = app.buttons[id]
        for _ in 0..<9 where !button.exists || !button.isHittable { scroll(app, up: true) }
        XCTAssertTrue(button.isHittable, String(app.debugDescription.suffix(7000)))
        return button
    }
    private func tap(_ app: XCUIApplication, _ id: String) { visibleButton(app, id).tap() }
    private func open(_ app: XCUIApplication) {
        app.buttons["Ustawienia"].tap()
        tap(app, "settings.avatar")
        XCTAssertTrue(element(app, "avatar.editor.previewNotice").waitForExistence(timeout: 10))
        let sample = app.buttons["avatar.editor.sample"]
        for _ in 0..<9 where !sample.exists || !sample.isHittable { scroll(app, up: true) }
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: sample)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
    private func choose(_ app: XCUIApplication) {
        tap(app, "avatar.editor.sample")
        let consent = app.switches["avatar.editor.consent"]
        for _ in 0..<9 where !consent.exists || !consent.isHittable { scroll(app, up: true) }
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
    }
    private func acceptAndSend(_ app: XCUIApplication) {
        acceptConsent(app)
        tap(app, "avatar.editor.submit")
    }
    private func status(_ app: XCUIApplication, contains: String) {
        let value = element(app, "avatar.editor.status")
        for _ in 0..<8 where !value.exists || !value.isHittable { scroll(app, up: false) }
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", contains), object: value)
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 10), .completed, String(app.debugDescription.suffix(7000)))
    }
    private func scroll(_ app: XCUIApplication, up: Bool) {
        let form = element(app, "avatar.editor.form")
        let target = form.exists ? form : app
        if up { target.swipeUp() } else { target.swipeDown() }
    }
    private func acceptConsent(_ app: XCUIApplication) {
        let consent = app.switches["avatar.editor.consent"]
        for _ in 0..<8 where !consent.exists { scroll(app, up: false) }
        for _ in 0..<8 {
            let center = consent.frame.midY
            if consent.isHittable && center > 170 && center < app.frame.maxY - 90 { break }
            scroll(app, up: center > app.frame.maxY - 90)
        }
        consent.coordinate(withNormalizedOffset: .init(dx: 0.93, dy: 0.5)).tap()
        let accepted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: consent)
        XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 5), .completed)
    }
    private func closeEditor(_ app: XCUIApplication) {
        app.navigationBars["Twoje zdjęcie"].buttons["Gotowe"].tap()
    }
    private func previewAndPublish(_ app: XCUIApplication, cancelFirst: Bool = false) {
        XCTAssertFalse(app.buttons["avatar.editor.publish"].exists)
        tap(app, "avatar.editor.loadApprovedPreview")
        displayApprovedImage(app)
        tap(app, "avatar.editor.publish")
        XCTAssertTrue(app.staticTexts["Opublikować to zdjęcie?"].waitForExistence(timeout: 5))
        displayApprovedImage(app, confirmation: true)
        attach(app, "owner-approved-image-publication-confirmation")
        if cancelFirst {
            app.buttons["avatar.editor.confirmCancel"].tap()
            status(app, contains: "zatwierdzone")
            XCTAssertFalse(element(app, "avatar.editor.pendingPublication").exists)
            // Reading status at AX XXXL can outlast the first preview. This is an explicit fetch.
            tap(app, "avatar.editor.loadApprovedPreview")
            displayApprovedImage(app)
            tap(app, "avatar.editor.publish")
            displayApprovedImage(app, confirmation: true)
        }
        tap(app, "avatar.editor.confirm")
    }
    private func displayApprovedImage(_ app: XCUIApplication, confirmation: Bool = false) {
        let image = element(app, "avatar.editor.approvedImage")
        let content = element(app, confirmation ? "avatar.editor.confirmationContent" : "avatar.editor.form")
        for _ in 0..<9 {
            let top = max(
                content.frame.minY,
                app.navigationBars[confirmation ? "Potwierdzenie" : "Twoje zdjęcie"].frame.maxY)
            let bottom = confirmation ? app.buttons["avatar.editor.confirm"].frame.minY : content.frame.maxY
            if image.exists && image.isHittable && image.frame.minY >= top && image.frame.maxY <= bottom {
                break
            }
            // safeAreaInset buttons overlap the ScrollView's accessibility frame. Keep the
            // gesture inside visible content, above the fixed controls.
            guard bottom > top else {
                XCTFail("No visible preview viewport")
                return
            }
            let down = !image.exists || image.frame.minY < top
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = content.frame.midX - app.frame.minX
            let low = top + (bottom - top) * 0.8 - app.frame.minY
            let high = top + (bottom - top) * 0.2 - app.frame.minY
            origin.withOffset(.init(dx: x, dy: down ? high : low)).press(
                forDuration: 0.05,
                thenDragTo: origin.withOffset(.init(dx: x, dy: down ? low : high)))
        }
        XCTAssertTrue(image.waitForExistence(timeout: 5) && image.isHittable)
        let top = max(
            content.frame.minY,
            app.navigationBars[confirmation ? "Potwierdzenie" : "Twoje zdjęcie"].frame.maxY)
        let bottom = confirmation ? app.buttons["avatar.editor.confirm"].frame.minY : content.frame.maxY
        XCTAssertGreaterThanOrEqual(image.frame.minY, top)
        XCTAssertLessThanOrEqual(image.frame.maxY, bottom)
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot())
        value.name = name
        value.lifetime = .keepAlways
        add(value)
    }
    func testSelectionRequiresExplicitConsentAndDoesNotAutomaticallyPublish() {
        let app = application()
        open(app)
        choose(app)
        XCTAssertFalse(visibleButton(app, "avatar.editor.submit").isEnabled)
        XCTAssertEqual(app.switches["avatar.editor.consent"].value as? String, "0")
        attach(app, "owner-photo-consent-before-upload")
        acceptAndSend(app)
        status(app, contains: "czeka na sprawdzenie")
        XCTAssertFalse(app.buttons["avatar.editor.publish"].exists)
        XCTAssertFalse(element(app, "avatar.editor.preview").exists)
        attach(app, "owner-photo-pending-review")
    }
    func testExpiredSelectionCanBeForgottenWithoutRetransmissionAndAllowsANewChoice() {
        expiredSelectionFlow(large: false)
    }
    func testExpiredSelectionRemainsRecoverableAtLargestAccessibilityTextSize() {
        expiredSelectionFlow(large: true)
    }
    private func expiredSelectionFlow(large: Bool) {
        let app = application("avatar-owner-expired", large: large)
        open(app)
        choose(app)
        acceptAndSend(app)
        status(app, contains: "czeka na sprawdzenie")
        tap(app, "avatar.editor.refresh")
        status(app, contains: "wygasł")
        XCTAssertFalse(app.buttons["avatar.editor.retry"].exists)
        XCTAssertFalse(app.buttons["avatar.editor.publish"].exists)
        XCTAssertFalse(visibleButton(app, "avatar.editor.recover").isEnabled)
        attach(app, "owner-photo-expired-before-forget")
        tap(app, "avatar.editor.discard")
        XCTAssertTrue(app.staticTexts["Zapomnieć tę próbę na urządzeniu?"].waitForExistence(timeout: 5))
        tap(app, "avatar.editor.confirm")
        status(app, contains: "Możesz wybrać nowe")
        choose(app)
        XCTAssertFalse(visibleButton(app, "avatar.editor.submit").isEnabled)
        acceptAndSend(app)
        status(app, contains: "czeka na sprawdzenie")
        attach(app, "owner-photo-expired-new-selection")
    }
    func testApprovedPhotoStillRequiresPublishAndClearRequiresConfirmation() {
        let app = application("avatar-owner-approved")
        open(app)
        choose(app)
        acceptAndSend(app)
        status(app, contains: "zatwierdzone")
        previewAndPublish(app)
        status(app, contains: "jest opublikowane")
        let published = element(app, "community.avatar.ownerEditor")
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Wczytane"), object: published)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        attach(app, "owner-photo-published")
        tap(app, "avatar.editor.clear")
        XCTAssertTrue(app.staticTexts["Wycofać zdjęcie i zgodę?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["avatar.editor.confirmCancel"].waitForExistence(timeout: 5))
        app.buttons["avatar.editor.confirmCancel"].tap()
        status(app, contains: "jest opublikowane")
        tap(app, "avatar.editor.clear")
        let confirm = app.buttons["avatar.editor.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        status(app, contains: "Brak opublikowanego")
        attach(app, "owner-photo-withdrawn")
    }
    func testLostPublicationReplyKeepsMetadataAndRecoversWithoutBlindPublishOrDiscard() {
        let app = application("avatar-owner-publish-lost")
        open(app)
        choose(app)
        acceptAndSend(app)
        status(app, contains: "zatwierdzone")
        previewAndPublish(app)
        status(app, contains: "Sprawdź aktualny stan")
        XCTAssertTrue(element(app, "avatar.editor.pendingPublication").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["avatar.editor.publish"].exists)
        XCTAssertFalse(app.buttons["avatar.editor.discard"].exists)
        XCTAssertFalse(app.buttons["avatar.editor.retry"].exists)
        XCTAssertFalse(element(app, "avatar.editor.preview").exists)
        attach(app, "owner-photo-publication-unknown-metadata")
        tap(app, "avatar.editor.recover")
        status(app, contains: "jest opublikowane")
        XCTAssertFalse(element(app, "avatar.editor.pendingPublication").exists)
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Wczytane"),
            object: element(app, "community.avatar.ownerEditor"))
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        attach(app, "owner-photo-publication-metadata-recovered")
    }
    func testClosingDraftDropsItsPreviewAndConsentOnReopen() {
        let app = application()
        open(app)
        choose(app)
        acceptConsent(app)
        closeEditor(app)
        tap(app, "settings.avatar")
        XCTAssertTrue(element(app, "avatar.editor.previewNotice").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "avatar.editor.preview").exists)
        XCTAssertFalse(app.switches["avatar.editor.consent"].exists)
        choose(app)
        XCTAssertEqual(app.switches["avatar.editor.consent"].value as? String, "0")
        XCTAssertFalse(visibleButton(app, "avatar.editor.submit").isEnabled)
    }
    func testLostReplyIsRecoveredAfterReopeningEditorWithoutRechoosingPhoto() {
        let app = application("avatar-owner-lost")
        open(app)
        choose(app)
        acceptAndSend(app)
        XCTAssertTrue(element(app, "avatar.editor.error").waitForExistence(timeout: 10))
        closeEditor(app)
        tap(app, "settings.avatar")
        status(app, contains: "czeka na sprawdzenie")
        XCTAssertFalse(element(app, "avatar.editor.preview").exists)
        XCTAssertFalse(app.switches["avatar.editor.consent"].exists)
        tap(app, "avatar.editor.recover")
        status(app, contains: "czeka na sprawdzenie")
        attach(app, "owner-photo-recovered-same-attempt")
    }
    func testBackgroundDropsUnsentPreviewAndClosesItsDomain() {
        let app = application()
        open(app)
        choose(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element(app, "community.preview.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "avatar.editor.preview").exists)
        app.buttons["Otwórz nową sesję testową"].tap()
        open(app)
        XCTAssertFalse(element(app, "avatar.editor.preview").exists)
        XCTAssertFalse(app.switches["avatar.editor.consent"].exists)
        attach(app, "owner-photo-after-background")
    }
    func testPublishedOwnPhotoReloadsWithoutLocationOrAnUnsentDraft() {
        let app = application("avatar-owner-no-location")
        open(app)
        choose(app)
        acceptAndSend(app)
        status(app, contains: "zatwierdzone")
        previewAndPublish(app)
        status(app, contains: "jest opublikowane")
        closeEditor(app)
        tap(app, "settings.avatar")
        status(app, contains: "jest opublikowane")
        let image = element(app, "community.avatar.ownerEditor")
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Wczytane"), object: image)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        XCTAssertFalse(element(app, "avatar.editor.preview").exists)
        attach(app, "owner-published-without-location")
        tap(app, "avatar.editor.clear")
        app.buttons["avatar.editor.confirm"].tap()
        status(app, contains: "Brak opublikowanego")
        XCTAssertFalse(image.exists)
        attach(app, "owner-withdrawn-without-location")
    }
    func testSystemPhotoPickerCanBeCancelledWithoutUploadingOrClosingTheEditor() {
        let app = application()
        open(app)
        tap(app, "avatar.editor.choose")
        let english = app.buttons["Cancel"]
        let polish = app.buttons["Anuluj"]
        XCTAssertTrue(english.waitForExistence(timeout: 10) || polish.waitForExistence(timeout: 3))
        if english.exists { english.tap() } else { polish.tap() }
        XCTAssertTrue(element(app, "avatar.editor.previewNotice").waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["avatar.editor.consent"].exists)
        XCTAssertFalse(element(app, "avatar.editor.preview").exists)
    }
    func testExistingApprovedPhotoNeedsCurrentPreviewAndSeparateConfirmationWithoutUpload() {
        let app = application("avatar-owner-existing-approved")
        open(app)
        status(app, contains: "zatwierdzone")
        XCTAssertFalse(element(app, "avatar.editor.preview").exists)
        XCTAssertFalse(app.switches["avatar.editor.consent"].exists)
        XCTAssertFalse(app.buttons["avatar.editor.recover"].exists)
        attach(app, "owner-existing-approved-without-journal")
        previewAndPublish(app, cancelFirst: true)
        status(app, contains: "jest opublikowane")
        attach(app, "owner-existing-photo-explicitly-published")
    }
    func testExistingPendingPhotoCannotPreviewOrPublishWithoutUploadJournal() {
        let app = application("avatar-owner-existing-pending")
        open(app)
        status(app, contains: "czeka na sprawdzenie")
        XCTAssertFalse(app.buttons["avatar.editor.loadApprovedPreview"].exists)
        XCTAssertFalse(app.buttons["avatar.editor.publish"].exists)
        XCTAssertFalse(element(app, "avatar.editor.approvedImage").exists)
        attach(app, "owner-existing-pending-not-publishable")
    }
    func testApprovedImageExpiresInConfirmationAndRequiresNewExplicitPreview() {
        let app = application("avatar-owner-existing-approved")
        open(app)
        tap(app, "avatar.editor.loadApprovedPreview")
        displayApprovedImage(app)
        tap(app, "avatar.editor.publish")
        displayApprovedImage(app, confirmation: true)
        let confirm = app.buttons["avatar.editor.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) && confirm.isEnabled)
        XCTAssertTrue(element(app, "avatar.editor.approvedPreviewUnavailable").waitForExistence(timeout: 35))
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertFalse(element(app, "avatar.editor.approvedImage").exists)
        attach(app, "owner-publication-confirmation-expired")
        app.buttons["avatar.editor.confirmCancel"].tap()
        status(app, contains: "zatwierdzone")
        previewAndPublish(app)
        status(app, contains: "jest opublikowane")
    }
    func testExistingApprovedPublicationConfirmationSupportsLargestAccessibilityText() {
        let app = application("avatar-owner-existing-approved", large: true)
        open(app)
        previewAndPublish(app, cancelFirst: true)
        status(app, contains: "jest opublikowane")
        attach(app, "owner-existing-approved-published-largest-text")
    }
    func testBackgroundDropsApprovedPreviewAndReopenRequiresNewFetchAndDisplay() {
        let app = application("avatar-owner-existing-approved")
        open(app)
        tap(app, "avatar.editor.loadApprovedPreview")
        displayApprovedImage(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element(app, "community.preview.closed").waitForExistence(timeout: 10))
        app.buttons["Otwórz nową sesję testową"].tap()
        open(app)
        status(app, contains: "zatwierdzone")
        XCTAssertFalse(element(app, "avatar.editor.approvedImage").exists)
        XCTAssertFalse(app.buttons["avatar.editor.publish"].exists)
        attach(app, "owner-approved-preview-after-background")
    }
    func testConsentAndSubmitAreReachableWithLargestAccessibilityText() {
        let app = application("avatar-owner", large: true)
        open(app)
        choose(app)
        XCTAssertFalse(visibleButton(app, "avatar.editor.submit").isEnabled)
        attach(app, "owner-photo-accessibility-consent")
        acceptAndSend(app)
        status(app, contains: "czeka na sprawdzenie")
        tap(app, "avatar.editor.clear")
        XCTAssertTrue(app.staticTexts["Wycofać zdjęcie i zgodę?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["avatar.editor.confirm"].isHittable)
        XCTAssertTrue(app.buttons["avatar.editor.confirmCancel"].isHittable)
        attach(app, "owner-photo-accessibility-clear")
        app.buttons["avatar.editor.confirm"].tap()
        status(app, contains: "Brak opublikowanego")
    }
}
