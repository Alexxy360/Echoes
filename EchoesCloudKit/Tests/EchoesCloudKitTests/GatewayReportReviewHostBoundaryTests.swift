import Foundation
import Observation
import Testing

@testable import EchoesCloudKit

private final class ReportHostReadStorage: GatewayReportReviewJournalStorage, @unchecked Sendable {
    let base = ReportJournalMemoryStorage(), readGate = ReviewStorageGate()
    func read(scope: GatewayReportReviewScope) throws -> Data? {
        readGate.blockIfArmed()
        return try base.read(scope: scope)
    }
    func write(_ data: Data, scope: GatewayReportReviewScope) throws { try base.write(data, scope: scope) }
    func erase(owner: PrivateAccountScope) throws { try base.erase(owner: owner) }
}
@MainActor private final class ReportHostAuthorizationProxy: GatewayAvatarAuthorizationSource {
    let base: PhotoAuthorization
    var afterToken: (() -> Void)?
    init(_ base: PhotoAuthorization) { self.base = base }
    var communityAuthorization: GatewayCommunityAuthorization? { base.communityAuthorization }
    func privateDataScope(configuration: CloudKitConfiguration) -> PrivateAccountScope? {
        base.privateDataScope(configuration: configuration)
    }
    func communityAccessToken(for value: GatewayCommunityAuthorization) async throws -> GatewaySecret {
        let result = try await base.communityAccessToken(for: value)
        let action = afterToken
        afterToken = nil
        action?()
        return result
    }
    func rejectCommunityAccess(for value: GatewayCommunityAuthorization) async {
        await base.rejectCommunityAccess(for: value)
    }
}
private func reportHostWait(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayReportReviewFailure.unavailable
}
private func reportPageItem(_ index: Int, fixture: ReportWireFixture) throws -> GatewayReportReviewItem {
    try .init(
        reportID: "community-v1-report-" + String(format: "%064x", index),
        createdAtMilliseconds: fixture.item.createdAtMilliseconds,
        expiresAtMilliseconds: fixture.item.expiresAtMilliseconds)
}

@Test @MainActor func reportReviewHostPagesReplaceTwentyRowsAndAllowEmptyProgressWithoutRetainingHistory()
    async throws
{
    let f = try ReportHostFixture()
    let first = try (1...20).map { try reportPageItem($0, fixture: f.wire) }
    let second = try (21...40).map { try reportPageItem($0, fixture: f.wire) }
    let a = try GatewayReportReviewCursor(first.last!.reportID)
    let b = try GatewayReportReviewCursor(second.last!.reportID)
    let c = try GatewayReportReviewCursor(reportPageItem(60, fixture: f.wire).reportID)
    await f.api.setPages([
        .init(items: first, next: a), .init(items: second, next: b), .init(items: [], next: c),
        .init(items: [try reportPageItem(61, fixture: f.wire)], next: nil),
    ])
    try await f.connect()
    try await f.host.refreshQueue()
    let old = try #require(f.host.page)
    #expect(f.host.queue == first && f.host.hasNextPage)
    try await f.host.nextPage(old)
    #expect(f.host.queue == second && f.host.hasNextPage)
    await #expect(throws: GatewayReportReviewFailure.stale) { try await f.host.nextPage(old) }
    try await f.host.nextPage(#require(f.host.page))
    #expect(f.host.queue.isEmpty && f.host.hasNextPage)
    try await f.host.nextPage(#require(f.host.page))
    #expect(f.host.queue.count == 1 && !f.host.hasNextPage)
    #expect(await f.api.cursors == [nil, a, b, c])
    let last = try #require(f.host.page)
    await #expect(throws: GatewayReportReviewFailure.stale) { try await f.host.nextPage(last) }
    f.host.invalidate()
    try await f.connect()
    #expect(f.host.page == nil && f.host.queue.isEmpty)
    await #expect(throws: GatewayReportReviewFailure.stale) { try await f.host.nextPage(last) }
}

@Test @MainActor func reportReviewHostRejectsInvalidPagesEvenFromCustomAPIAndNeverInspectsExpiredMetadata()
    async throws
{
    let f = try ReportHostFixture()
    let first = try reportPageItem(1, fixture: f.wire)
    let second = try reportPageItem(2, fixture: f.wire)
    let many = try (1...21).map { try reportPageItem($0, fixture: f.wire) }
    let future = try GatewayReportReviewItem(
        reportID: first.reportID, createdAtMilliseconds: f.wire.now + 1,
        expiresAtMilliseconds: f.wire.now + 1 + 2_592_000_000)
    for page in [
        GatewayReportReviewPage(items: [first, first], next: nil), .init(items: [second, first], next: nil),
        .init(items: many, next: nil), .init(items: [future], next: nil),
        .init(items: [second], next: try .init(first.reportID)),
    ] {
        await f.api.setPages([page])
        try await f.connect()
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) { try await f.host.refreshQueue() }
        #expect(f.host.queue.isEmpty && f.host.page == nil)
    }
    await f.api.setPages([.init(items: [f.wire.item], next: nil)])
    try await f.host.refreshQueue()
    f.clock.move(wall: 2_592_000_000, monotonic: 2_592_000)
    #expect(f.host.queue.isEmpty)
    let before = await f.api.calls
    await #expect(throws: GatewayReportReviewFailure.stale) { try await f.host.inspect(f.wire.item) }
    #expect(await f.api.calls == before)
}

@Test @MainActor func reportReviewHostMissingMessageCanBeDismissedButNeverHiddenOrSentToDecisionAPI()
    async throws
{
    let f = try ReportHostFixture()
    let response = try reportBody(f.wire.inspection, ["message": NSNull()])
    let token = try await f.authorization.communityAccessToken(
        for: #require(f.authorization.communityAuthorization))
    let value = try await reportClient(
        ReportHTTPStub(response), clock: f.clock, origin: URL(string: f.api.origin)!
    ).inspect(f.wire.item, token: token)
    await f.api.setInspection(value)
    let shown = try await f.show()
    #expect(f.host.material(for: shown)?.message == nil && f.host.canDecide && !f.host.canHideMessage)
    let before = f.authorization.tokenCalls
    await #expect(throws: GatewayReportReviewFailure.invalidInput) {
        try await f.host.decide(.hideMessage, presentation: shown)
    }
    #expect(await f.api.decisions.isEmpty)
    #expect(f.authorization.tokenCalls == before)
    try await f.host.decide(.dismiss, presentation: shown)
    #expect(await f.api.decisions.first?.verdict == .dismiss)
}

@Test @MainActor
func reportReviewHostRejectsAccountChangeDuringTheLastJournalReadBeforeInspectOrAfterResponse() async throws {
    for phase in ["token", "response"] {
        let f = try ReportHostFixture()
        let storage = ReportHostReadStorage()
        let source = ReportHostAuthorizationProxy(f.authorization)
        let journal = GatewayReportReviewJournal(storage: storage)
        let host = try GatewayReportReviewHost(
            api: f.api, configuration: .init(origin: URL(string: f.api.origin)!),
            cloudKit: f.scope.owner.configuration,
            authorization: source, journal: journal, isEnabled: { true }, date: { f.clock.date() },
            uptime: { f.clock.up() })
        host.setForeground(true)
        try await host.connect()
        try await host.refreshQueue()
        if phase == "token" {
            source.afterToken = { storage.readGate.arm() }
        } else {
            await f.api.pause("inspect")
        }
        let running = Task { try await host.inspect(f.wire.item) }
        defer {
            storage.readGate.release()
            running.cancel()
        }
        if phase == "response" {
            try await f.api.gate.wait()
            storage.readGate.arm()
            await f.api.gate.release()
        }
        try await reportHostWait { storage.readGate.hasEntered() }
        f.authorization.cloudName = "another-cloud-account"
        storage.readGate.release()
        await #expect(throws: GatewayReportReviewHostFailure.superseded) { try await running.value }
        #expect(host.presentation == nil && !host.isConnected)
        #expect(await f.api.calls == (phase == "token" ? ["queue"] : ["queue", "inspect"]))
        host.invalidate()
    }
}

@Test @MainActor func reportReviewHostSlowDurableWriteCannotSendExpiredInspectionAndKeepsIDsForRecovery()
    async throws
{
    let f = try ReportHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let running = Task { try await f.host.decide(.hideMessage, presentation: shown) }
    defer {
        f.storage.gate.release()
        running.cancel()
    }
    try await reportHostWait { f.storage.gate.hasEntered() }
    f.clock.move(wall: 90_000, monotonic: 90)
    f.storage.gate.release()
    await #expect(throws: GatewayReportReviewFailure.stale) { try await running.value }
    #expect(await f.api.decisions.isEmpty)
    let entry = try #require(f.host.pendingOperation)
    #expect(entry.phase == .dispatched)
    try await f.host.recover()
    #expect(f.host.outcome == .notApplied && f.host.pendingOperation?.intent == entry.intent)
}

@Test @MainActor func reportReviewHostACKAfterReceiptExpiryNeverClaimsSuccessAndOnlyRecoversExactIntent()
    async throws
{
    let f = try ReportHostFixture()
    let shown = try await f.show()
    await f.api.pause("decide")
    let running = Task { try await f.host.decide(.hideMessage, presentation: shown) }
    try await f.api.gate.wait()
    f.clock.move(wall: 90_000, monotonic: 90)
    await f.api.gate.release()
    await #expect(throws: GatewayReportReviewFailure.stale) { try await running.value }
    #expect(f.host.pendingOperation?.phase == .dispatched && f.host.outcome == nil)
    let saved = try #require(f.host.pendingOperation)
    try await f.host.recover()
    #expect(await f.api.recoveries == [saved.intent])
    guard case .confirmed = f.host.outcome else {
        Issue.record("Applied decision must recover")
        return
    }
    #expect(await f.api.decisions.count == 1)
}

@Test @MainActor func reportReviewHostObservedScopeAndExpiryCannotReviveAfterABAReturn() async throws {
    for mode in ["scope", "activation", "expiry"] {
        let f = try ReportHostFixture()
        let shown = try await f.show()
        if mode == "scope" {
            f.authorization.cloudName = "other-cloud"
        } else if mode == "activation" {
            f.flags.enabled = false
        } else {
            f.clock.move(wall: 90_000)
        }
        #expect(f.host.material(for: shown) == nil && f.host.presentation == nil)
        if mode == "scope" {
            f.authorization.cloudName = "synthetic-review-cloud"
        } else if mode == "activation" {
            f.flags.enabled = true
        } else {
            f.clock.move(wall: -90_000)
        }
        #expect(f.host.material(for: shown) == nil && f.host.presentation == nil && !f.host.canDecide)
        await #expect(throws: GatewayReportReviewHostFailure.displayRequired) {
            try await f.host.decide(.hideMessage, presentation: shown)
        }
        #expect(await f.api.decisions.isEmpty)
    }
}

@Test @MainActor func reportReviewHostActualHTTP401RejectsSessionWhileRole403PreservesOrdinaryAccount()
    async throws
{
    for (status, code) in [(401, "INVALID_SESSION"), (403, "REPORT_REVIEW_SCOPE"), (403, "INVALID_SESSION")] {
        let f = try ReportHostFixture()
        let response = try reportJSON(["protocolVersion": 1, "error": code], status: status)
        let api = try reportClient(
            ReportHTTPStub(response), clock: f.clock, origin: URL(string: f.api.origin)!)
        let host = try GatewayReportReviewHost(
            api: api, configuration: .init(origin: URL(string: f.api.origin)!),
            cloudKit: f.scope.owner.configuration,
            authorization: f.authorization, journal: f.journal, isEnabled: { true })
        host.setForeground(true)
        try await host.connect()
        if status == 401 {
            await #expect(throws: GatewayFailure.signInRequired) { try await host.refreshQueue() }
            #expect(f.authorization.rejected == 1 && !host.isConnected)
        } else if code == "REPORT_REVIEW_SCOPE" {
            await #expect(throws: GatewayReportReviewFailure.denied) { try await host.refreshQueue() }
            #expect(f.authorization.rejected == 0 && host.isConnected && host.isRoleDenied)
        } else {
            await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
                try await host.refreshQueue()
            }
            #expect(f.authorization.rejected == 0 && host.isConnected)
        }
        host.invalidate()
    }
}

private final class ReportHostAdvancingClock: @unchecked Sendable {
    let base: Int
    private let lock = NSLock()
    private var start: TimeInterval?
    init(_ base: Int) { self.base = base }
    // Setup can be slow under a full parallel suite. Start real passage only once the
    // material and observation are installed; the tested one-second deadline is unchanged.
    func resume() { lock.withLock { start = ProcessInfo.processInfo.systemUptime } }
    private func elapsed() -> TimeInterval {
        lock.withLock { start.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0 }
    }
    func date() -> Date { .init(timeIntervalSince1970: Double(base) / 1000 + elapsed()) }
    func uptime() -> TimeInterval { 100 + elapsed() }
}
private final class ReportHostNotification: @unchecked Sendable {
    let lock = NSLock()
    private var value = false
    func mark() { lock.withLock { value = true } }
    func read() -> Bool { lock.withLock { value } }
}
@Test @MainActor func reportReviewHostLocalDeadlineNotifiesAndClosesTextWithoutNetworkPolling() async throws {
    let f = try ReportHostFixture()
    let clock = ReportHostAdvancingClock(f.wire.now)
    let reply = try reportBody(f.wire.inspection, ["inspectionExpiresAt": f.wire.now + 1000])
    let token = try await f.authorization.communityAccessToken(
        for: #require(f.authorization.communityAuthorization))
    let inspection = try await reportClient(
        ReportHTTPStub(reply), clock: f.clock, origin: URL(string: f.api.origin)!
    ).inspect(f.wire.item, token: token)
    await f.api.setInspection(inspection)
    let host = try GatewayReportReviewHost(
        api: f.api, configuration: .init(origin: URL(string: f.api.origin)!),
        cloudKit: f.scope.owner.configuration,
        authorization: f.authorization, journal: f.journal, isEnabled: { true }, date: { clock.date() },
        uptime: { clock.uptime() })
    host.setForeground(true)
    try await host.connect()
    try await host.refreshQueue()
    try await host.inspect(f.wire.item)
    let shown = try #require(host.presentation)
    let notification = ReportHostNotification()
    withObservationTracking {
        _ = host.presentationRevision
    } onChange: {
        notification.mark()
    }
    clock.resume()
    try await reportHostWait { notification.read() }
    #expect(host.presentation == nil && host.material(for: shown) == nil)
    #expect(await f.api.calls == ["queue", "inspect"])
}
