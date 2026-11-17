import Foundation
import Observation
import Testing

@testable import EchoesCloudKit

private let ownerFlowA = "6b000000-0000-4000-8000-000000000001"
private let ownerFlowB = "6b000000-0000-4000-8000-000000000002"

private final class OwnerFlowClock: @unchecked Sendable {
    let lock = NSLock()
    private var time = Date().timeIntervalSince1970
    func now() -> Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ value: Double) { lock.withLock { time += value } }
}
private actor OwnerFlowJournal: GatewayAvatarUploadJournaling {
    let real: GatewayAvatarUploadJournal
    let opening = PhotoGate(), preparing = PhotoGate(), transitioning = PhotoGate(), removing = PhotoGate()
    var lease: GatewayAvatarUploadJournalLease?
    var failPrepare = false, failTransition = false, failRemove = false
    init(_ real: GatewayAvatarUploadJournal) { self.real = real }
    func fail(prepare: Bool = false, transition: Bool = false, remove: Bool = false) {
        failPrepare = prepare
        failTransition = transition
        failRemove = remove
    }
    func open(scope: GatewayAvatarUploadScope) async throws -> GatewayAvatarUploadJournalLease {
        let result = try await real.open(scope: scope)
        lease = result
        await opening.enter()
        return result
    }
    func fence(_ lease: GatewayAvatarUploadJournalLease) async { await real.fence(lease) }
    func pending(lease: GatewayAvatarUploadJournalLease) async throws -> GatewayAvatarUploadJournalEntry? {
        try await real.pending(lease: lease)
    }
    func read() async throws -> GatewayAvatarUploadJournalEntry? {
        try await real.pending(lease: #require(lease))
    }
    func prepareUpload(
        intent: GatewayAvatarUploadIntent, avatar: PreparedAvatar, lease: GatewayAvatarUploadJournalLease
    ) async throws -> GatewayAvatarUploadJournalEntry {
        let result = try await real.prepareUpload(intent: intent, avatar: avatar, lease: lease)
        await preparing.enter()
        if failPrepare { throw GatewayAvatarUploadJournalFailure.unavailable }
        return result
    }
    func prepareClear(
        requestID: String, expectedGeneration: Int, replacing: GatewayAvatarUploadJournalEntry?,
        lease: GatewayAvatarUploadJournalLease
    ) async throws -> GatewayAvatarUploadJournalEntry {
        try await real.prepareClear(
            requestID: requestID, expectedGeneration: expectedGeneration, replacing: replacing, lease: lease)
    }
    func source(for entry: GatewayAvatarUploadJournalEntry, lease: GatewayAvatarUploadJournalLease)
        async throws -> Data
    { try await real.source(for: entry, lease: lease) }
    func transition(
        _ entry: GatewayAvatarUploadJournalEntry, to phase: GatewayAvatarJournalPhase,
        lease: GatewayAvatarUploadJournalLease
    ) async throws -> GatewayAvatarUploadJournalEntry {
        let result = try await real.transition(entry, to: phase, lease: lease)
        await transitioning.enter()
        if failTransition { throw GatewayAvatarUploadJournalFailure.unavailable }
        return result
    }
    func remove(_ entry: GatewayAvatarUploadJournalEntry, lease: GatewayAvatarUploadJournalLease) async throws
    {
        await removing.enter()
        if failRemove { throw GatewayAvatarUploadJournalFailure.unavailable }
        try await real.remove(entry, lease: lease)
    }
}

private func ownerSnapshot(
    generation: Int = 0, request: String? = nil, version: String? = nil,
    status: GatewayAvatarOwnerStatus = .none
) throws -> GatewayAvatarOwnerSnapshot {
    try .init(
        data: JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1, "generation": generation, "requestID": request as Any? ?? NSNull(),
            "versionID": version as Any? ?? NSNull(),
            "publishedVersionID": status == .published ? version as Any? ?? NSNull() : NSNull(),
            "reviewRevision": version == nil ? NSNull() : "6b000000-0000-4000-8000-000000000099",
            "status": status.rawValue,
        ]))
}
private actor OwnerFlowAPI: GatewayAvatarMutationAPI {
    nonisolated let origin = "https://owner-flow.example.invalid"
    enum Fault: Sendable { case lostReply, beforeAccept, denied, unknown, wrongVersion, wrongGeneration }
    struct Call: Sendable {
        let account: String
        let action: GatewayAvatarMutation
    }
    var calls: [Call] = []
    var values: [String: GatewayAvatarOwnerSnapshot] = [:]
    var faults: [String: Fault] = [:]
    var pauseAction = ""
    let gate = PhotoGate()
    var before: (@Sendable (GatewayAvatarMutation) async throws -> Void)?
    func captured() -> [Call] { calls }
    func fail(_ action: String, _ fault: Fault) { faults[action] = fault }
    func pause(_ action: String) async {
        pauseAction = action
        await gate.arm()
    }
    func beforeEach(_ value: @escaping @Sendable (GatewayAvatarMutation) async throws -> Void) {
        before = value
    }
    func set(_ snapshot: GatewayAvatarOwnerSnapshot, account: String = ownerFlowA) {
        values[account] = snapshot
    }
    func review(_ status: GatewayAvatarOwnerStatus, account: String = ownerFlowA) throws {
        let old = try values[account] ?? ownerSnapshot()
        values[account] = try ownerSnapshot(
            generation: old.generation, request: old.requestID, version: old.versionID, status: status)
    }
    func perform(_ operation: GatewayAvatarMutation, token: GatewaySecret) async throws
        -> GatewayAvatarOwnerSnapshot
    {
        let account = String(token.value.prefix(36))
        calls.append(.init(account: account, action: operation))
        try await before?(operation)
        let fault = faults.removeValue(forKey: operation.action)
        if fault == .denied { throw GatewayFailure.signInRequired }
        if fault == .beforeAccept { throw GatewayAvatarMutationFailure.unavailable }
        if fault == .unknown { throw NSError(domain: "PRIVATE-SERVER-URL-AND-TOKEN-DO-NOT-EXPOSE", code: 7) }
        let old = try values[account] ?? ownerSnapshot()
        var result: GatewayAvatarOwnerSnapshot
        switch operation {
        case .status: result = old
        case .upload(let intent, _):
            if old.requestID != intent.requestID && old.generation != intent.expectedGeneration {
                throw GatewayAvatarMutationFailure.stale
            }
            result = try ownerSnapshot(
                generation: intent.expectedGeneration + 1, request: intent.requestID,
                version: intent.versionID, status: .pendingReview)
        case .recover(let id):
            guard old.requestID == id else { throw GatewayAvatarMutationFailure.stale }
            result = old
        case .publish(let id):
            guard old.requestID == id, old.status == .approved || old.status == .published else {
                throw GatewayAvatarMutationFailure.pending
            }
            result = try ownerSnapshot(
                generation: old.generation, request: id, version: old.versionID, status: .published)
        case .clear(let id, let previous):
            guard old.generation == previous || old.requestID == id && old.generation == previous + 1 else {
                throw GatewayAvatarMutationFailure.stale
            }
            result = try ownerSnapshot(generation: previous + 1, request: id)
        }
        values[account] = result
        if fault == .wrongVersion {
            result = try ownerSnapshot(
                generation: result.generation, request: result.requestID,
                version: UUID().uuidString.lowercased(), status: result.status)
        }
        if fault == .wrongGeneration {
            result = try ownerSnapshot(
                generation: result.generation + 1, request: result.requestID, version: result.versionID,
                status: result.status)
        }
        if pauseAction == operation.action { await gate.enter() }
        if fault == .lostReply { throw GatewayAvatarMutationFailure.unavailable }
        return result
    }
}
@MainActor @Observable private final class OwnerFlowFlags { var enabled = true }
@MainActor private struct OwnerFlowFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "echoes-owner-flow-" + UUID().uuidString)
    let flags = OwnerFlowFlags(), clock = OwnerFlowClock()
    let authorization: PhotoAuthorization
    let configuration: GatewayConfiguration
    let cloudKit: CloudKitConfiguration
    let scope: GatewayAvatarUploadScope
    let api = OwnerFlowAPI()
    let journal: OwnerFlowJournal
    let real: GatewayAvatarUploadJournal
    let controller: GatewayAvatarOwnerController
    let avatar: PreparedAvatar
    init() throws {
        authorization = try .init()
        try authorization.select(ownerFlowA)
        configuration = try .init(origin: URL(string: "https://owner-flow.example.invalid")!)
        cloudKit = try .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
        let native = try #require(authorization.communityAuthorization)
        scope = try .init(
            configuration: configuration,
            privateScope: #require(authorization.privateDataScope(configuration: cloudKit)),
            binding: native.identity.binding)
        avatar = try AvatarPreparer.prepare(MutationWireFixture().image)
        real = try .init(root: root, clock: { [clock] in clock.now() })
        journal = .init(real)
        controller = try .init(
            api: api, configuration: configuration, cloudKit: cloudKit, authorization: authorization,
            journal: journal, isEnabled: { [flags] in flags.enabled })
    }
    func cleanup() {
        controller.invalidate()
        try? FileManager.default.removeItem(at: root)
    }
    func seed(phase: GatewayAvatarJournalPhase = .dispatched, generation: Int = 0) async throws
        -> GatewayAvatarUploadJournalEntry
    {
        let lease = try await journal.open(scope: scope)
        let intent = try GatewayAvatarUploadIntent(
            requestID: mutationRequestID, versionID: mutationVersionID, expectedGeneration: generation)
        let entry = try await journal.prepareUpload(intent: intent, avatar: avatar, lease: lease)
        return phase == .prepared ? entry : try await journal.transition(entry, to: .dispatched, lease: lease)
    }
    func actions() async -> [String] { await api.captured().map { $0.action.action } }
}

@Test @MainActor func avatarOwnerSubmitPersistsPreparedBytesAndDispatchBeforeNetworkWithoutAutoPublication()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    await f.api.beforeEach { action in
        if case .upload(let intent, let image) = action {
            let stored = try #require(await f.journal.read())
            #expect(
                stored.intent == .upload(intent) && stored.phase == .dispatched && image == f.avatar.image)
        }
    }
    try await f.controller.connect()
    #expect(await f.actions() == [])
    try await f.controller.submit(f.avatar, consentVersion: 1)
    #expect(await f.actions() == ["status", "upload"])
    #expect(
        f.controller.snapshot?.status == .pendingReview && f.controller.pendingOperation?.phase == .staged)
    #expect(!f.controller.needsRefresh && !f.controller.isBusy)
    await #expect(throws: GatewayAvatarMutationFailure.pending) { try await f.controller.publish() }
    #expect(!(await f.actions()).contains("publish"))
    try await f.api.review(.approved)
    try await f.controller.refresh()
    #expect(f.controller.snapshot?.status == .approved)
    #expect(!(await f.actions()).contains("publish"))
    try await f.controller.publish()
    #expect(f.controller.snapshot?.status == .published && f.controller.pendingOperation == nil)
    #expect(try await f.journal.read() == nil)
}

@Test @MainActor func avatarOwnerRequiresConsentAndRefusesOverwritingPendingUpload() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await #expect(throws: GatewayAvatarMutationFailure.invalidInput) {
        try await f.controller.submit(f.avatar, consentVersion: 0)
    }
    #expect(await f.actions() == [])
    try await f.controller.submit(f.avatar, consentVersion: 1)
    let pending = f.controller.pendingOperation
    await #expect(throws: GatewayAvatarUploadJournalFailure.pendingExists) {
        try await f.controller.submit(f.avatar, consentVersion: 1)
    }
    #expect(try await f.journal.read() == pending)
    #expect(await f.actions() == ["status", "upload"])
}

@Test @MainActor func avatarOwnerLostUploadReplyRestoresIDsAndRecoveryNeverRetransmitsJPEG() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await f.api.fail("upload", .lostReply)
    await #expect(throws: GatewayAvatarMutationFailure.unavailable) {
        try await f.controller.submit(f.avatar, consentVersion: 1)
    }
    let original = try #require(await f.journal.read())
    #expect(original.phase == .dispatched && f.controller.needsRefresh)
    f.controller.invalidate()
    try await f.controller.connect()
    #expect(f.controller.pendingOperation == original)
    #expect(await f.actions() == ["status", "upload"])
    try await f.controller.recover()
    #expect(
        f.controller.pendingOperation?.intent == original.intent
            && f.controller.pendingOperation?.phase == .staged)
    #expect(await f.actions() == ["status", "upload", "recover"])
    try await f.controller.retryUpload()
    #expect(await f.actions() == ["status", "upload", "recover", "status"])
}

@Test @MainActor func avatarOwnerExplicitRetryReusesExactRequestVersionGenerationConsentAndJPEG() async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await f.api.fail("upload", .beforeAccept)
    await #expect(throws: GatewayAvatarMutationFailure.unavailable) {
        try await f.controller.submit(f.avatar, consentVersion: 1)
    }
    let saved = try #require(await f.journal.read())
    try await f.controller.retryUpload()
    let uploads = await f.api.captured().map(\.action).filter(\.isUpload)
    #expect(uploads.count == 2 && uploads[0] == uploads[1])
    if case .upload(let intent, let bytes) = uploads[1] {
        #expect(saved.intent == .upload(intent) && bytes == f.avatar.image)
    }
    #expect(await f.actions() == ["status", "upload", "status", "upload"])
}

@Test @MainActor func avatarOwnerLostPublishReplyReconcilesPublicationWithoutSecondPublish() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    try await f.controller.submit(f.avatar, consentVersion: 1)
    try await f.api.review(.approved)
    await f.api.fail("publish", .lostReply)
    await #expect(throws: GatewayAvatarMutationFailure.unavailable) { try await f.controller.publish() }
    #expect(try await f.journal.read()?.phase == .publishing)
    try await f.controller.refresh()
    #expect(f.controller.snapshot?.status == .published && f.controller.pendingOperation == nil)
    #expect((await f.actions()).filter { $0 == "publish" }.count == 1)
}

@Test @MainActor func avatarOwnerClearDropsPreparedSourceAndRetriesSameIntentThroughClear() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    try await f.controller.submit(f.avatar, consentVersion: 1)
    let upload = try #require(f.controller.pendingOperation)
    await f.api.fail("clear", .lostReply)
    await #expect(throws: GatewayAvatarMutationFailure.unavailable) { try await f.controller.clear() }
    let clear = try #require(await f.journal.read())
    #expect(!clear.hasSource && clear.phase == .dispatched && clear.intent != upload.intent)
    await f.api.fail("recover", .unknown)
    try await f.controller.recover()
    let calls = await f.api.captured().map(\.action)
    let clears = calls.filter { $0.action == "clear" }
    #expect(clears.count == 2 && clears[0] == clears[1] && !calls.contains { $0.action == "recover" })
    #expect(
        f.controller.snapshot?.status == GatewayAvatarOwnerStatus.none && f.controller.pendingOperation == nil
    )
}

@Test @MainActor func avatarOwnerInactiveOrMismatchedConfigurationNeverOpensAnAccountOrDispatches()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let inactive = try GatewayAvatarOwnerController(
        api: f.api, configuration: f.configuration, cloudKit: f.cloudKit, authorization: f.authorization,
        journal: f.journal)
    await #expect(throws: GatewayAvatarMutationFailure.unavailable) { try await inactive.connect() }
    let wrong = try GatewayConfiguration(origin: URL(string: "https://wrong-owner.example.invalid")!)
    #expect(throws: GatewayFailure.configuration) {
        try GatewayAvatarOwnerController(
            api: f.api, configuration: wrong, cloudKit: f.cloudKit, authorization: f.authorization,
            journal: f.journal)
    }
    f.authorization.foreground = false
    await #expect(throws: GatewayFailure.signInRequired) { try await f.controller.connect() }
    let ownerDirectory = f.root.appendingPathComponent("EchoesAvatarUploads").appendingPathComponent(
        f.scope.privateScope.digest)
    #expect(!FileManager.default.fileExists(atPath: ownerDirectory.path))
    #expect(await f.actions() == [])
}

@Test @MainActor func avatarOwnerInvalidationKeepsSingleSlotUntilAnIgnoringProviderActuallyReturns()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await f.api.pause("status")
    let old = Task { try await f.controller.refresh() }
    try await f.api.gate.wait()
    f.controller.invalidate()
    try f.authorization.select(ownerFlowB)
    #expect(f.controller.isBusy && !f.controller.isConnected && f.controller.snapshot == nil)
    await #expect(throws: GatewayAvatarMutationFailure.busy) { try await f.controller.connect() }
    await #expect(throws: GatewayAvatarMutationFailure.busy) { try await f.controller.clear() }
    await f.api.gate.release()
    await #expect(throws: GatewayAvatarOwnerFailure.superseded) { try await old.value }
    #expect(!f.controller.isBusy)
    try await f.controller.connect()
    try await f.controller.refresh()
    #expect(f.controller.snapshot?.generation == 0)
    let calls = await f.api.captured()
    #expect(calls.map(\.account) == [ownerFlowA, ownerFlowB])
}

@Test @MainActor func avatarOwnerLateJournalOpenCannotReconnectAnotherAccountOrReleaseAnUnsettledSlot()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    await f.journal.opening.arm()
    let old = Task { try await f.controller.connect() }
    try await f.journal.opening.wait()
    f.controller.invalidate()
    try f.authorization.select(ownerFlowB)
    await #expect(throws: GatewayAvatarMutationFailure.busy) { try await f.controller.connect() }
    await f.journal.opening.release()
    await #expect(throws: GatewayAvatarOwnerFailure.superseded) { try await old.value }
    #expect(!f.controller.isConnected && f.controller.pendingOperation == nil)
    try await f.controller.connect()
    try await f.controller.refresh()
    #expect(await f.actions() == ["status"])
    #expect((await f.api.captured()).first?.account == ownerFlowB)
}

@Test @MainActor func avatarOwnerICloudChangeDuringFreshTokenPreventsStatusAndMutationDispatch() async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await f.authorization.gate.arm()
    let old = Task { try await f.controller.submit(f.avatar, consentVersion: 1) }
    try await f.authorization.gate.wait()
    f.authorization.cloudName = "different-icloud-without-cached-session-change"
    #expect(f.controller.snapshot == nil && !f.controller.isConnected)
    await f.authorization.gate.release()
    await #expect(throws: GatewayAvatarOwnerFailure.superseded) { try await old.value }
    #expect(await f.actions() == [])
    #expect(try await f.journal.read() == nil)
}

@Test @MainActor func avatarOwnerABARejectsLateUploadAndFreshConnectionRecoversSameAccountIDs() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await f.api.pause("upload")
    let old = Task { try await f.controller.submit(f.avatar, consentVersion: 1) }
    try await f.api.gate.wait()
    let original = try #require(await f.journal.read())
    try f.authorization.select(ownerFlowB)
    try f.authorization.select(ownerFlowA)
    #expect(f.controller.snapshot == nil && f.controller.pendingOperation == nil)
    await f.api.gate.release()
    await #expect(throws: GatewayAvatarOwnerFailure.superseded) { try await old.value }
    #expect(try await f.journal.read() == original)
    try await f.controller.connect()
    try await f.controller.recover()
    #expect(
        f.controller.pendingOperation?.intent == original.intent
            && f.controller.pendingOperation?.phase == .staged)
    #expect(await f.actions() == ["status", "upload", "recover"])
}

@Test @MainActor func avatarOwnerBackgroundOrFeatureStopDuringDurableWritesNeverDispatchesJPEG() async throws
{
    for boundary in 0..<2 {
        let f = try OwnerFlowFixture()
        defer { f.cleanup() }
        try await f.controller.connect()
        let gate = boundary == 0 ? f.journal.preparing : f.journal.transitioning
        await gate.arm()
        let old = Task { try await f.controller.submit(f.avatar, consentVersion: 1) }
        try await gate.wait()
        if boundary == 0 { f.authorization.foreground = false } else { f.flags.enabled = false }
        await gate.release()
        await #expect(throws: GatewayAvatarOwnerFailure.superseded) { try await old.value }
        #expect(await f.actions() == ["status"])
        let saved = try #require(await f.journal.read())
        #expect(saved.phase == (boundary == 0 ? .prepared : .dispatched))
        f.authorization.foreground = true
        f.flags.enabled = true
        try await f.controller.connect()
        try await f.controller.retryUpload()
        #expect(f.controller.pendingOperation?.intent == saved.intent)
        #expect(await f.actions() == ["status", "status", "upload"])
    }
}

@Test @MainActor func avatarOwnerUnknownLocalWriteResultKeepsIDsAndDoesNotSendBeforePersistenceReturns()
    async throws
{
    for boundary in 0..<2 {
        let f = try OwnerFlowFixture()
        defer { f.cleanup() }
        try await f.controller.connect()
        await f.journal.fail(prepare: boundary == 0, transition: boundary == 1)
        await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
            try await f.controller.submit(f.avatar, consentVersion: 1)
        }
        let saved = try #require(await f.journal.read())
        #expect(f.controller.needsRefresh)
        #expect(await f.actions() == ["status"])
        await f.journal.fail()
        try await f.controller.refresh()
        try await f.controller.retryUpload()
        #expect(f.controller.pendingOperation?.intent == saved.intent)
        #expect(await f.actions() == ["status", "status", "status", "upload"])
    }
}

@Test @MainActor func avatarOwnerLate401NeverRejectsNewNativeAccount() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let gate = PhotoGate()
    await gate.arm()
    try await f.controller.connect()
    await f.api.beforeEach { _ in await gate.enter() }
    await f.api.fail("status", .denied)
    let old = Task { try await f.controller.refresh() }
    try await gate.wait()
    try f.authorization.select(ownerFlowB)
    await gate.release()
    await #expect(throws: GatewayAvatarOwnerFailure.superseded) { try await old.value }
    #expect(
        f.authorization.rejected == 0
            && f.authorization.communityAuthorization?.identity.accountID == ownerFlowB)
    try await f.controller.connect()
    try await f.controller.refresh()
    #expect(f.controller.isConnected && f.controller.snapshot?.generation == 0)
}

@Test @MainActor func avatarOwnerCurrent401ClosesPresentationButPreservesRecoverableIntent() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    try await f.controller.submit(f.avatar, consentVersion: 1)
    let saved = try #require(f.controller.pendingOperation)
    await f.api.fail("status", .denied)
    await #expect(throws: GatewayFailure.signInRequired) { try await f.controller.refresh() }
    #expect(f.authorization.rejected == 1 && !f.controller.isConnected && f.controller.snapshot == nil)
    try f.authorization.select(ownerFlowA)
    try await f.controller.connect()
    #expect(f.controller.pendingOperation == saved)
    try await f.controller.recover()
    #expect(f.controller.pendingOperation?.intent == saved.intent)
}

@Test @MainActor func avatarOwnerErasureDuringUploadPreventsLateACKAndCannotRecreateLocalSource() async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await f.api.pause("upload")
    let old = Task { try await f.controller.submit(f.avatar, consentVersion: 1) }
    try await f.api.gate.wait()
    try await f.real.erase(scope: f.scope.privateScope)
    await f.api.gate.release()
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) { try await old.value }
    #expect(!f.controller.isConnected && f.controller.pendingOperation == nil)
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) { try await f.controller.connect() }
    #expect(await f.actions() == ["status", "upload"])
}

@Test @MainActor func avatarOwnerClearRejectsRolledBackGenerationBeforeReplacingPendingSource() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let saved = try await f.seed(generation: 5)
    try await f.controller.connect()
    await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) { try await f.controller.clear() }
    #expect(try await f.journal.read() == saved)
    #expect(await f.actions() == ["status"])
}

@Test @MainActor func avatarOwnerRejectsWrongUploadAndPublishVersionOrGenerationWithoutForgettingIntent()
    async throws
{
    for action in ["upload", "publish"] {
        for fault in [OwnerFlowAPI.Fault.wrongVersion, .wrongGeneration] {
            let f = try OwnerFlowFixture()
            defer { f.cleanup() }
            try await f.controller.connect()
            if action == "publish" {
                try await f.controller.submit(f.avatar, consentVersion: 1)
                try await f.api.review(.approved)
            }
            await f.api.fail(action, fault)
            await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
                if action == "upload" {
                    try await f.controller.submit(f.avatar, consentVersion: 1)
                } else {
                    try await f.controller.publish()
                }
            }
            let saved = try #require(await f.journal.read())
            #expect(saved.phase == (action == "upload" ? .dispatched : .publishing))
            #expect(f.controller.needsRefresh && f.controller.snapshot == nil)
            try await f.controller.refresh()
            if action == "upload" {
                #expect(f.controller.pendingOperation?.intent == saved.intent)
            } else {
                #expect(f.controller.snapshot?.status == .published && f.controller.pendingOperation == nil)
            }
        }
    }
}

@Test @MainActor func avatarOwnerDifferentDeviceSelectionRequiresExplicitDiscardAndFreshGeneration()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let saved = try await f.seed()
    let other = try ownerSnapshot(
        generation: 2, request: UUID().uuidString.lowercased(), version: UUID().uuidString.lowercased(),
        status: .approved)
    await f.api.set(other)
    try await f.controller.connect()
    try await f.controller.refresh()
    #expect(f.controller.pendingOperation == saved && f.controller.snapshot == other)
    await #expect(throws: GatewayAvatarMutationFailure.stale) { try await f.controller.retryUpload() }
    #expect(try await f.journal.read() == saved)
    try await f.controller.discardUnsentOrSuperseded()
    #expect(f.controller.pendingOperation == nil)
    try await f.controller.submit(f.avatar, consentVersion: 1)
    let uploads = await f.api.captured().map(\.action).filter(\.isUpload)
    #expect(uploads.count == 1)
    if case .upload(let intent, _) = uploads[0] {
        #expect(intent.expectedGeneration == 2 && saved.intent != .upload(intent))
    }
}

@Test @MainActor func avatarOwnerExplicitDiscardAllowsOnlyUnsentOrVerifiedSupersededOperations() async throws
{
    for phase in [GatewayAvatarJournalPhase.prepared, .dispatched] {
        let f = try OwnerFlowFixture()
        defer { f.cleanup() }
        let saved = try await f.seed(phase: phase)
        try await f.controller.connect()
        if phase == .prepared {
            try await f.controller.discardUnsentOrSuperseded()
            #expect(try await f.journal.read() == nil)
        } else {
            await #expect(throws: GatewayAvatarMutationFailure.pending) {
                try await f.controller.discardUnsentOrSuperseded()
            }
            #expect(try await f.journal.read() == saved)
        }
        #expect(await f.actions() == ["status"])
    }
}

@Test @MainActor func avatarOwnerExpiredSourceCanRecoverAndPublishButCannotRetransmit() async throws {
    for accepted in [false, true] {
        let f = try OwnerFlowFixture()
        defer { f.cleanup() }
        let saved = try await f.seed()
        if accepted {
            await f.api.set(
                try ownerSnapshot(
                    generation: 1, request: mutationRequestID, version: mutationVersionID,
                    status: .pendingReview))
        }
        f.clock.advance(7 * 86400)
        try await f.controller.connect()
        #expect(
            f.controller.pendingOperation?.hasSource == false
                && f.controller.pendingOperation?.intent == saved.intent)
        if accepted {
            try await f.controller.recover()
            try await f.api.review(.approved)
            try await f.controller.publish()
            #expect(f.controller.snapshot?.status == .published && f.controller.pendingOperation == nil)
            #expect(await f.actions() == ["recover", "status", "publish"])
        } else {
            await #expect(throws: GatewayAvatarUploadJournalFailure.sourceUnavailable) {
                try await f.controller.retryUpload()
            }
            #expect(f.controller.pendingOperation?.intent == saved.intent)
            try await f.controller.clear()
            #expect(f.controller.pendingOperation == nil)
            #expect(await f.actions() == ["status", "status", "clear"])
        }
    }
}

@Test @MainActor func avatarOwnerCallerCancellationKeepsBusyUntilReturnAndThenRecoversUnknownUpload()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await f.api.pause("upload")
    let old = Task { try await f.controller.submit(f.avatar, consentVersion: 1) }
    try await f.api.gate.wait()
    old.cancel()
    await #expect(throws: GatewayAvatarMutationFailure.busy) { try await f.controller.clear() }
    #expect(f.controller.isBusy)
    await f.api.gate.release()
    await #expect(throws: GatewayFailure.cancelled) { try await old.value }
    #expect(!f.controller.isBusy && f.controller.isConnected)
    #expect(try await f.journal.read()?.phase == .dispatched)
    try await f.controller.recover()
    #expect(f.controller.pendingOperation?.phase == .staged)
    #expect(await f.actions() == ["status", "upload", "recover"])
}

@Test @MainActor func avatarOwnerFailedCompletionPersistenceIsReconciledWithoutDuplicatePublication()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    try await f.controller.submit(f.avatar, consentVersion: 1)
    try await f.api.review(.approved)
    await f.journal.fail(remove: true)
    await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) { try await f.controller.publish() }
    #expect(try await f.journal.read()?.phase == .publishing)
    await f.journal.fail()
    try await f.controller.refresh()
    #expect(f.controller.snapshot?.status == .published && f.controller.pendingOperation == nil)
    #expect((await f.actions()).filter { $0 == "publish" }.count == 1)
}

@Test @MainActor func avatarOwnerRotatedDurableLeaseStopsDispatchAndLateFencePreservesNewLease() async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await f.authorization.gate.arm()
    let old = Task { try await f.controller.refresh() }
    try await f.authorization.gate.wait()
    let newer = try await f.real.open(scope: f.scope)
    await f.authorization.gate.release()
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) { try await old.value }
    #expect(await f.actions() == [])
    #expect(!f.controller.isConnected)
    #expect(try await f.real.pending(lease: newer) == nil)
}

@Test @MainActor func avatarOwnerUnknownProviderFailureHasNoPrivateDetailsAndPreservesJournal() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    await f.api.fail("upload", .unknown)
    await #expect(throws: GatewayAvatarMutationFailure.unavailable) {
        try await f.controller.submit(f.avatar, consentVersion: 1)
    }
    #expect(try await f.journal.read()?.phase == .dispatched)
    #expect(f.controller.needsRefresh && f.controller.snapshot == nil)
}

private actor OwnerWireSequence: GatewayAvatarMutationTransport {
    var replies: [MutationWireCase]
    var sent: [String] = []
    init(_ replies: [MutationWireCase]) { self.replies = replies }
    func send(_ request: URLRequest, isUpload: Bool) async throws -> GatewayAvatarHTTPResponse {
        let row = try #require(replies.first)
        replies.removeFirst()
        #expect(request.url?.lastPathComponent == row.operation.action && !isUpload)
        #expect(request.httpBody == (try row.operation.wire()).body)
        sent.append(row.operation.action)
        return row.response
    }
}

@Test @MainActor func avatarOwnerRecoveryAndPublicationConsumeConcreteServerWireFixturesWithoutUpload()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let wire = try MutationWireFixture()
    guard case .upload(let intent, _) = try wire.entry("upload-pending").operation else {
        throw GatewayAvatarMutationFailure.invalidInput
    }
    let transport = try OwnerWireSequence([
        wire.entry("recover-pending"), wire.entry("status-approved"), wire.entry("publish-published"),
    ])
    let configuration = try GatewayConfiguration(origin: mutationOrigin)
    let source = try GatewayAvatarUploadScope(
        configuration: configuration, privateScope: f.scope.privateScope,
        binding: #require(f.authorization.communityAuthorization).identity.binding)
    let lease = try await f.journal.open(scope: source)
    let prepared = try await f.journal.prepareUpload(intent: intent, avatar: f.avatar, lease: lease)
    _ = try await f.journal.transition(prepared, to: .dispatched, lease: lease)
    let api = GatewayAvatarMutationHTTPClient(
        configuration: configuration, transport: transport, isEnabled: { true })
    let controller = try GatewayAvatarOwnerController(
        api: api, configuration: configuration, cloudKit: f.cloudKit, authorization: f.authorization,
        journal: f.journal, isEnabled: { true })
    defer { controller.invalidate() }
    try await controller.connect()
    try await controller.recover()
    #expect(controller.snapshot?.status == .pendingReview && controller.pendingOperation?.phase == .staged)
    try await controller.publish()
    #expect(controller.snapshot?.status == .published && controller.pendingOperation == nil)
    #expect(await transport.sent == ["recover", "status", "publish"])
    #expect(try await f.journal.read() == nil)
}
