import AuthenticationServices
import CloudKit
import Foundation
import Testing

@testable import EchoesCloudKit

@MainActor private final class DeletionAppleState: AppleGatewayIdentitySource {
    var state: AppleGatewayCredentialState = .authorized
    var calls = 0
    func credentialState(userID: String) async throws -> AppleGatewayCredentialState {
        calls += 1
        return state
    }
}
@MainActor private final class DeletionAppleSheet: AppleGatewayAuthorizer {
    var calls = 0, cancels = 0
    var user = "native-apple-A"
    var hold = false, ignoreCancellation = false
    var pending: CheckedContinuation<AppleGatewayProof, any Error>?
    var hook: (() -> Void)?
    func authorize(challenge: GatewayChallenge) async throws -> AppleGatewayProof {
        calls += 1
        hook?()
        if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try flowProof(user)
    }
    func cancel() {
        cancels += 1
        if !ignoreCancellation {
            pending?.resume(throwing: GatewayFailure.cancelled)
            pending = nil
        }
    }
    func finish() throws {
        pending?.resume(returning: try flowProof(user))
        pending = nil
    }
}
@MainActor private final class DeletionHostFixture {
    let flow: DeletionFlowFixture
    let apple = DeletionAppleState(), sheet = DeletionAppleSheet(), center = NotificationCenter()
    var current: GatewayAuthenticatedIdentity?
    let host: GatewayDeletionHost
    init() throws {
        let flow = try DeletionFlowFixture()
        self.flow = flow
        // The callback intentionally reads a separate holder to avoid capturing a partly initialized self.
        let identity = IdentityHolder(.init(accountID: flowAccountID, binding: flow.binding))
        holder = identity
        host = GatewayDeletionHost(
            api: flow.api, cloudKitAccount: flow.account, apple: apple, authorizer: sheet,
            currentAuthentication: { identity.value },
            resumeBindings: { name in
                try GatewayDeletionController.resumeBindings(
                    configuration: flow.config, origin: flow.api.origin,
                    storage: flow.storage, cloudKitRecordName: name)
            },
            makeController: { binding in
                #expect(binding == flow.binding)
                return flow.controller()
            }, isEnabled: { flow.enabled }, notificationCenter: center)
    }
    private let holder: IdentityHolder
    @MainActor private final class IdentityHolder {
        var value: GatewayAuthenticatedIdentity?
        init(_ value: GatewayAuthenticatedIdentity?) { self.value = value }
    }
    func setAuthentication(_ value: GatewayAuthenticatedIdentity?) { holder.value = value }
    func start() async throws -> GatewayDeletionProgress {
        await host.activate()
        host.ask(.deleteAccount)
        let confirmation = try #require(host.confirmation)
        await host.confirm(confirmation)
        return try #require(host.progress)
    }
}

@Test @MainActor func completedReceiptRemovalNeedsExplicitConfirmationButNoNewAppleProof()
    async throws
{
    let f = try DeletionHostFixture()
    f.flow.cleanup.complete = true
    let initial = try await f.start()
    await f.host.continueDeletion(journalID: initial.journalID)
    #expect(f.host.progress?.completed == true)
    f.apple.state = .revoked
    f.setAuthentication(nil)
    await f.host.activate()
    let before = try f.flow.storage.read()
    let calls = (f.sheet.calls, f.apple.calls, f.flow.api.statusCalls, f.flow.api.challengePurposes.count)
    f.host.ask(.forgetCompleted(journalID: initial.journalID))
    #expect(f.host.confirmation?.buttonTitle == "Usuń potwierdzenie")
    f.host.cancelConfirmation()
    #expect(try f.flow.storage.read() == before)
    f.host.ask(.forgetCompleted(journalID: initial.journalID))
    let selected = try #require(f.host.confirmation)
    f.host.confirmFromUserAction(selected)
    f.host.cancelConfirmation()
    for _ in 0..<1000 where f.host.isBusy { await Task.yield() }
    #expect(f.host.requests.isEmpty && f.host.progress == nil && f.host.phase == .ready)
    #expect(try f.flow.storage.journal().requests.isEmpty)
    #expect(
        (f.sheet.calls, f.apple.calls, f.flow.api.statusCalls, f.flow.api.challengePurposes.count) == calls)
    await f.host.confirm(selected)
    #expect(try f.flow.storage.journal().requests.isEmpty)
}

@Test @MainActor func incompleteOrChangedIdentityCannotConfirmLocalReceiptRemoval() async throws {
    let f = try DeletionHostFixture()
    let initial = try await f.start()
    f.host.ask(.forgetCompleted(journalID: initial.journalID))
    #expect(f.host.confirmation == nil)
    f.flow.cleanup.complete = true
    await f.host.continueDeletion(journalID: initial.journalID)
    f.host.ask(.forgetCompleted(journalID: initial.journalID))
    let selected = try #require(f.host.confirmation)
    let before = try f.flow.storage.read()
    f.flow.owner.name = "owner-B"
    await f.host.confirm(selected)
    #expect(try f.flow.storage.read() == before)
    #expect(f.host.requests.isEmpty && f.host.errorMessage != nil)
}

@Test @MainActor func localReceiptConfirmationDoesNotDiscardAConcurrentlyRotatedRecoveryTicket()
    async throws
{
    let f = try DeletionHostFixture()
    f.flow.cleanup.complete = true
    let initial = try await f.start()
    await f.host.continueDeletion(journalID: initial.journalID)
    f.host.ask(.forgetCompleted(journalID: initial.journalID))
    let selected = try #require(f.host.confirmation)
    // A separate coordinator has its own native session; only protected storage is shared.
    let external = try DeletionFlowFixture(storage: f.flow.storage)
    external.api.activeTicket = f.flow.api.activeTicket
    external.api.serverAck = true
    external.api.serverCompleted = true
    let newer = try await external.controller().recover(
        challenge: flowChallenge(), proof: flowProof(), expectedAccountID: flowAccountID,
        journalID: initial.journalID)
    let before = try f.flow.storage.read()
    let sheets = f.sheet.calls
    await f.host.confirm(selected)
    #expect(try f.flow.storage.read() == before)
    #expect(f.host.errorMessage != nil && f.host.requests == [newer])
    #expect(f.sheet.calls == sheets)
}

@Test @MainActor func deletionHostRequiresOneUseConfirmationAndPinsTheSignedInAppleAndApplicationAccount()
    async throws
{
    let f = try DeletionHostFixture()
    await f.host.activate()
    #expect(f.flow.api.requestCalls == 0 && f.sheet.calls == 0)
    f.host.ask(.deleteAccount)
    let confirmed = try #require(f.host.confirmation)
    await f.host.confirm(confirmed)
    #expect(f.host.progress?.accountID == flowAccountID)
    #expect(f.flow.api.challengePurposes == [false])
    #expect(f.flow.api.requestCalls == 1 && f.sheet.calls == 1 && f.apple.calls == 1)
    await f.host.confirm(confirmed)
    #expect(f.flow.api.requestCalls == 1 && f.host.phase == .ready)
}

@Test @MainActor func staleConfirmationCannotEraseANewerConfirmationOrDispatchAfterAuthenticationChanges()
    async throws
{
    let f = try DeletionHostFixture()
    await f.host.activate()
    f.host.ask(.deleteAccount)
    let old = try #require(f.host.confirmation)
    f.host.ask(.recover(journalID: nil))
    let newer = try #require(f.host.confirmation)
    await f.host.confirm(old)
    #expect(f.host.confirmation == newer)
    f.setAuthentication(nil)
    await f.host.confirm(newer)
    #expect(f.sheet.calls == 0 && f.flow.api.challengePurposes.isEmpty)
}

@Test @MainActor func cancelledConfirmationAndBackgroundNeverPresentASheetOrStartADeletion() async throws {
    let f = try DeletionHostFixture()
    await f.host.activate()
    f.host.ask(.deleteAccount)
    let old = try #require(f.host.confirmation)
    f.host.cancelConfirmation()
    await f.host.confirm(old)
    f.host.ask(.deleteAccount)
    let beforeBackground = try #require(f.host.confirmation)
    f.host.suspend()
    await f.host.confirm(beforeBackground)
    #expect(f.sheet.calls == 0 && f.flow.api.requestCalls == 0 && f.host.requests.isEmpty)
}

@Test @MainActor func freshDeletionRejectsAnotherAppleUserAndRevokedNativeProofBeforeDispatch() async throws {
    let f = try DeletionHostFixture()
    await f.host.activate()
    f.sheet.user = "another-native-Apple-user"
    f.host.ask(.deleteAccount)
    await f.host.confirm(try #require(f.host.confirmation))
    #expect(f.flow.api.requestCalls == 0 && f.host.progress == nil)
    f.sheet.user = "native-apple-A"
    f.apple.state = .revoked
    await f.host.activate()
    f.host.ask(.deleteAccount)
    await f.host.confirm(try #require(f.host.confirmation))
    #expect(f.flow.api.requestCalls == 0 && f.flow.api.ackCalls == 0)
}

@Test @MainActor func aCloudSwitchDuringTheAppleSheetClearsHintsAndNeverStartsTheDeletion() async throws {
    let f = try DeletionHostFixture()
    await f.host.activate()
    f.sheet.hook = { f.flow.owner.name = "owner-B" }
    f.host.ask(.deleteAccount)
    await f.host.confirm(try #require(f.host.confirmation))
    #expect(f.host.requests.isEmpty && f.host.progress == nil)
    #expect(f.flow.api.requestCalls == 0 && f.flow.api.ackCalls == 0)
}

@Test @MainActor func returningFromTheHostsOwnSheetDoesNotCancelItButBackgroundFencesItsLateProof()
    async throws
{
    let f = try DeletionHostFixture()
    await f.host.activate()
    f.sheet.hold = true
    f.sheet.ignoreCancellation = true
    f.host.ask(.deleteAccount)
    let confirmation = try #require(f.host.confirmation)
    let work = Task { await f.host.confirm(confirmation) }
    for _ in 0..<1000 {
        if f.sheet.pending != nil { break }
        await Task.yield()
    }
    let cancels = f.sheet.cancels
    await f.host.activate()
    #expect(f.sheet.cancels == cancels && f.host.phase == .authorizing)
    f.host.suspend()
    try f.sheet.finish()
    await work.value
    #expect(f.host.phase == .suspended && f.host.progress == nil && f.flow.api.requestCalls == 0)
}

@Test @MainActor func existingDeletionResumesWithTheTicketAfterAppleRevocationWithoutAnotherNativeSheet()
    async throws
{
    let f = try DeletionHostFixture()
    f.flow.cleanup.complete = true
    let stored = try await f.flow.request(f.flow.controller())
    f.apple.state = .revoked
    f.setAuthentication(nil)
    await f.host.activate()
    #expect(f.host.requests.count == 1 && f.sheet.calls == 0 && f.apple.calls == 0)
    await f.host.continueDeletion(journalID: stored.journalID)
    #expect(f.host.progress?.completed == true && f.sheet.calls == 0 && f.apple.calls == 0)
}

@Test @MainActor func anUnknownInitialResultLoadsTheProtectedTicketAndPollDoesNotReplayAppleProof()
    async throws
{
    let f = try DeletionHostFixture()
    f.flow.api.loseRequest = true
    await f.host.activate()
    f.host.ask(.deleteAccount)
    await f.host.confirm(try #require(f.host.confirmation))
    let pending = try #require(f.host.requests.first)
    #expect(f.host.progress == nil && f.sheet.calls == 1)
    await f.host.poll(journalID: pending.journalID)
    #expect(f.host.progress?.status != nil && f.flow.api.requestProofs == [true, false])
    #expect(f.sheet.calls == 1 && f.flow.api.ackCalls == 0)
}

@Test @MainActor func recoveryUsesItsOwnPurposeAndPreservesASameOwnerStoredJob() async throws {
    let f = try DeletionHostFixture()
    let original = try await f.start()
    f.host.ask(.recover(journalID: original.journalID))
    await f.host.confirm(try #require(f.host.confirmation))
    #expect(f.flow.api.challengePurposes == [false, true])
    #expect(f.host.progress?.journalID == original.journalID && f.flow.api.recoveryCalls == 1)
    #expect(f.flow.api.ackCalls == 0)
}

@Test @MainActor func recoveringAMissingTicketBindsTheServerAccountBeforeItFencesLocalAccess() async throws {
    let f = try DeletionHostFixture()
    f.flow.api.activeTicket = try .create()
    f.setAuthentication(nil)
    await f.host.activate()
    f.host.ask(.recover(journalID: nil))
    await f.host.confirm(try #require(f.host.confirmation))
    #expect(f.host.progress?.accountID == flowAccountID)
    #expect(f.flow.fences == 1 && f.flow.api.recoveryCalls == 1 && f.flow.api.requestCalls == 0)
}

@Test @MainActor func nativeRevocationPausesTheUIButDoesNotDeleteTheTicketOrRequireFreshAppleForItsResume()
    async throws
{
    let f = try DeletionHostFixture()
    let first = try await f.start()
    f.apple.state = .revoked
    f.center.post(name: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil)
    #expect(f.host.requests.isEmpty && f.host.progress == nil)
    for _ in 0..<1000 {
        if f.host.phase == .ready { break }
        await Task.yield()
    }
    #expect(f.host.requests.count == 1)
    let calls = f.sheet.calls
    await f.host.poll(journalID: first.journalID)
    #expect(f.host.progress?.journalID == first.journalID && f.sheet.calls == calls)
}

@Test @MainActor func disabledOrCorruptStorageNeverShowsAPretendEmptyAccountOrStartsANativeSheet()
    async throws
{
    let f = try DeletionHostFixture()
    f.flow.enabled = false
    await f.host.activate()
    f.host.ask(.deleteAccount)
    #expect(f.host.confirmation == nil && f.sheet.calls == 0)
    f.flow.enabled = true
    f.flow.storage.set(Data("invalid journal".utf8))
    await f.host.activate()
    f.host.ask(.deleteAccount)
    #expect(f.host.phase == .unavailable && f.host.confirmation == nil && f.host.requests.isEmpty)
    #expect(f.sheet.calls == 0 && f.flow.api.requestCalls == 0)
}

@Test @MainActor func unacceptedInitialRequestCanBeExplicitlyReconfirmedAfterARecoveryReportsNoJob()
    async throws
{
    let f = try DeletionHostFixture()
    f.flow.failFence = true
    await f.host.activate()
    f.host.ask(.deleteAccount)
    await f.host.confirm(try #require(f.host.confirmation))
    f.flow.failFence = false
    await f.host.activate()
    let first = try #require(f.host.requests.first)
    #expect(first.canRetryInitialRequest && f.flow.api.requestCalls == 0)
    f.setAuthentication(nil)
    f.host.ask(.recover(journalID: first.journalID))
    await f.host.confirm(try #require(f.host.confirmation))
    #expect(f.host.requests.first?.needsFreshProof == true)
    let ticket = try #require(try f.flow.storage.journal().requests.first?.ticket)
    f.host.ask(.retryInitial(journalID: first.journalID))
    await f.host.confirm(try #require(f.host.confirmation))
    #expect(f.host.progress?.journalID == first.journalID)
    #expect(f.flow.api.activeTicket == ticket && f.flow.api.requestCalls == 1)
    #expect(f.flow.api.challengePurposes == [false, true, false])
}

@Test @MainActor func aQueuedIdentityNotificationCannotReopenADeletionFeatureAfterItStops() async throws {
    let f = try DeletionHostFixture()
    _ = try await f.start()
    f.center.post(name: Notification.Name.CKAccountChanged, object: nil)
    f.host.stop()
    for _ in 0..<100 { await Task.yield() }
    #expect(f.host.phase == .suspended && f.host.requests.isEmpty && f.host.confirmation == nil)
}

@Test @MainActor func theUIConfirmationIsReservedSynchronouslyBeforeAutomaticAlertDismissal() async throws {
    let f = try DeletionHostFixture()
    await f.host.activate()
    f.host.ask(.deleteAccount)
    let selected = try #require(f.host.confirmation)
    f.host.confirmFromUserAction(selected)
    #expect(f.host.phase == .authorizing && f.host.confirmation == nil)
    f.host.cancelConfirmation()  // SwiftUI's automatic isPresented=false after the button action.
    for _ in 0..<1000 {
        if f.host.phase == .ready { break }
        await Task.yield()
    }
    #expect(f.flow.api.requestCalls == 1 && f.sheet.calls == 1)
    f.host.confirmFromUserAction(selected)
    #expect(f.flow.api.requestCalls == 1)
}
