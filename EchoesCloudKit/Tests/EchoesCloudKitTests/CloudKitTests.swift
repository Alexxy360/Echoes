import CloudKit
import Foundation
import Testing

@testable import EchoesCloudKit

@MainActor
private final class AccountStub: CloudKitAccountSource {
    var status: CloudKitAccountAvailability = .available
    var name = "account-A"
    var identityRequests = 0
    var failure: (any Error)?
    var suspendedIdentity: CheckedContinuation<String, Never>?
    var suspendNextIdentity = false

    func availability() async throws -> CloudKitAccountAvailability {
        if let failure { throw failure }
        return status
    }
    func userRecordName() async throws -> String {
        identityRequests += 1
        if suspendNextIdentity {
            suspendNextIdentity = false
            return await withCheckedContinuation { suspendedIdentity = $0 }
        }
        return name
    }
}

@Test func rejectsGuessedOrMismatchedContainerConfiguration() throws {
    for value in [
        "", "mpvEcho.Echo", "iCloud.", "iCloud.test.*", "iCloud.test..app", " iCloud.test.app",
    ] {
        #expect(throws: CloudKitFailure.self) {
            try CloudKitConfiguration(containerIdentifier: value, environment: .development)
        }
    }
    // This identifier is synthetic and never sent to Apple.
    let configuration = try CloudKitConfiguration(
        containerIdentifier: "iCloud.example.test", environment: .development)
    var entitlements: [String: Any] = [
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-identifiers": ["iCloud.example.test"],
        "com.apple.developer.icloud-container-environment": "Development",
    ]
    try configuration.validateEntitlements(entitlements)
    entitlements["com.apple.developer.icloud-container-environment"] = "Production"
    #expect(throws: CloudKitFailure.self) { try configuration.validateEntitlements(entitlements) }
    #expect(throws: CloudKitFailure.self) { try configuration.validateEntitlements([:]) }
}

@Test @MainActor func absentOrRestrictedAccountNeverRequestsAnIdentity() async {
    for (status, expected) in [
        (CloudKitAccountAvailability.noAccount, CloudKitFailure.notAuthenticated),
        (.restricted, .restricted), (.temporarilyUnavailable, .unavailable), (.unknown, .unavailable),
    ] {
        let source = AccountStub()
        source.status = status
        let session = CloudKitAccountSession(source: source)
        await session.refresh()
        #expect(session.userRecordName == nil)
        #expect(session.state == .unavailable)
        #expect(session.failure == expected)
        #expect(source.identityRequests == 0)
    }
}

@Test @MainActor func switchingAccountClearsOldIdentityBeforeNetworkCompletes() async {
    let source = AccountStub()
    let session = CloudKitAccountSession(source: source)
    await session.refresh()
    #expect(session.userRecordName == "account-A")
    let oldRevision = session.identityRevision
    source.suspendNextIdentity = true
    let request = Task { await session.refresh() }
    while source.suspendedIdentity == nil { await Task.yield() }
    #expect(session.userRecordName == nil)
    #expect(session.identityRevision > oldRevision)
    #expect(session.state == .checking)
    source.suspendedIdentity?.resume(returning: "account-B")
    await request.value
    #expect(session.userRecordName == "account-B")
}

@Test @MainActor func staleAccountResponseCannotRestoreIdentityAfterLogout() async {
    let source = AccountStub()
    source.suspendNextIdentity = true
    let session = CloudKitAccountSession(source: source)
    let oldRequest = Task { await session.refresh() }
    while source.suspendedIdentity == nil { await Task.yield() }
    source.status = .noAccount
    await session.refresh()
    source.suspendedIdentity?.resume(returning: "account-A")
    await oldRequest.value
    #expect(session.userRecordName == nil)
    #expect(session.failure == .notAuthenticated)
}

@Test @MainActor func stoppingMonitoringInvalidatesInFlightResult() async {
    let source = AccountStub()
    source.suspendNextIdentity = true
    let session = CloudKitAccountSession(source: source)
    session.startMonitoring()
    session.startMonitoring()
    let request = Task { await session.refresh() }
    while source.suspendedIdentity == nil { await Task.yield() }
    session.stopMonitoring()
    source.suspendedIdentity?.resume(returning: "account-A")
    await request.value
    #expect(session.state == .idle)
    #expect(session.userRecordName == nil)
}

@Test @MainActor func failedRefreshRemovesPreviousAccountAndRedactsDiagnostics() async {
    let source = AccountStub()
    let session = CloudKitAccountSession(source: source)
    await session.refresh()
    source.failure = NSError(
        domain: "test", code: 9, userInfo: [NSLocalizedDescriptionKey: "secret account token"])
    await session.refresh()
    #expect(session.userRecordName == nil)
    #expect(session.failure == .unavailable)
    #expect(session.failure?.localizedDescription.contains("secret") == false)
}

@Test @MainActor func cancelledRefreshDoesNotLeaveSpinnerOrIdentity() async {
    let source = AccountStub()
    source.suspendNextIdentity = true
    let session = CloudKitAccountSession(source: source)
    let request = Task { await session.refresh() }
    while source.suspendedIdentity == nil { await Task.yield() }
    request.cancel()
    source.suspendedIdentity?.resume(returning: "account-A")
    await request.value
    #expect(session.state == .idle)
    #expect(session.userRecordName == nil)
}

@Test func cloudKitErrorsPreserveRetryHintsWithoutBlindWriteRetry() {
    let throttled = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 45.0])
    #expect(CloudKitFailure.classify(throttled) == .retryLater(after: 45))
    #expect(CloudKitFailure.classify(CKError(.serverRecordChanged)) == .conflict)
    #expect(CloudKitFailure.classify(CKError(.partialFailure)) == .partialFailure)
    #expect(CloudKitFailure.classify(CKError(.missingEntitlement)) == .configuration)
    #expect(CloudKitFailure.classify(CKError(.permissionFailure)) == .permissionDenied)
    #expect(CloudKitFailure.classify(CancellationError()) == .cancelled)
}
