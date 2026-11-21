import Foundation
import Testing

@testable import EchoesCloudKit

@MainActor private struct CommunityBootstrapFixture {
    let configuration = try! GatewayConfiguration(origin: URL(string: "https://bootstrap.example.invalid")!)
    let uploadScope: GatewayAvatarReviewScope
    let photoScope: GatewayAvatarReportReviewScope
    init() throws {
        let scope = try reviewStoreScope(origin: configuration.origin.absoluteString)
        uploadScope = scope
        photoScope = try .init(configuration: configuration, owner: scope.owner, binding: scope.binding)
    }
    func load(_ bootstrap: GatewayCommunityBootstrap, current: @escaping @MainActor () -> Bool = { true })
        async throws -> GatewayCommunityBootstrap.Pending
    {
        try await bootstrap.load(
            configuration: configuration, owner: uploadScope.owner, binding: uploadScope.binding,
            isCurrent: current)
    }
}
@MainActor private final class CommunityBootstrapGate {
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false
    func hold() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            suspended = continuation
            entered = true
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        suspended?.resume()
        suspended = nil
    }
}

@Test @MainActor func communityBootstrapRestoresBothExactIntentsWithoutRotatingLeasesOrWriting() async throws
{
    let f = try CommunityBootstrapFixture()
    let uploadStorage = ReviewMemoryStorage()
    let photoStorage = ReportedPhotoJournalMemoryStorage()
    let uploads = GatewayAvatarReviewJournal(storage: uploadStorage)
    let photos = GatewayAvatarReportReviewJournal(storage: photoStorage)
    let uploadLease = try await uploads.open(scope: f.uploadScope)
    let photoLease = try await photos.open(scope: f.photoScope)
    let upload = try await uploads.prepare(reviewStoreIntent(), lease: uploadLease)
    let photo = try await photos.prepare(reportedPhotoStoreIntent(), lease: photoLease)
    let retiring = try await photos.retiring(photo, lease: photoLease)
    let writes = uploadStorage.writes + photoStorage.writes
    let bootstrap = GatewayCommunityBootstrap(upload: uploads, reportedPhoto: photos)
    let value = try await f.load(bootstrap)
    #expect(value.upload == upload.intent && value.reportedPhoto == retiring.intent)
    #expect(bootstrap.isCurrent(value) && !bootstrap.isOpening)
    #expect(uploadStorage.writes + photoStorage.writes == writes)
    #expect(try await uploads.pending(lease: uploadLease) == upload)
    #expect(try await photos.pending(lease: photoLease) == retiring)
}
@Test(arguments: [false, true]) @MainActor func communityBootstrapFailureOfEitherPeekProducesNoSnapshot(
    photoFails: Bool
) async throws {
    let f = try CommunityBootstrapFixture()
    var uploadCalls = 0
    var photoCalls = 0
    let bootstrap = GatewayCommunityBootstrap(
        upload: { scope in
            #expect(scope == f.uploadScope)
            uploadCalls += 1
            if !photoFails { throw GatewayCommunityFailure.storage }
            return nil
        },
        reportedPhoto: { scope in
            #expect(scope == f.photoScope)
            photoCalls += 1
            throw GatewayCommunityFailure.storage
        })
    await #expect(throws: GatewayCommunityFailure.storage) { try await f.load(bootstrap) }
    #expect(uploadCalls == 1 && photoCalls == (photoFails ? 1 : 0) && !bootstrap.isOpening)
}
@Test(arguments: [false, true]) @MainActor func communityBootstrapRechecksScopeAfterEachPeek(
    photoChanges: Bool
) async throws {
    let f = try CommunityBootstrapFixture()
    var current = true
    var photoCalls = 0
    let bootstrap = GatewayCommunityBootstrap(
        upload: { _ in
            if !photoChanges { current = false }
            return nil
        },
        reportedPhoto: { _ in
            photoCalls += 1
            current = false
            return nil
        })
    await #expect(throws: GatewayCommunityFailure.superseded) {
        try await f.load(bootstrap, current: { current })
    }
    #expect(photoCalls == (photoChanges ? 1 : 0) && !bootstrap.isOpening)
}
@Test(arguments: [false, true]) @MainActor func communityBootstrapInvalidationKeepsSlotUntilOldPeekReturns(
    photoWaits: Bool
) async throws {
    let f = try CommunityBootstrapFixture()
    let gate = CommunityBootstrapGate()
    var photoCalls = 0
    let bootstrap = GatewayCommunityBootstrap(
        upload: { _ in
            if !photoWaits { await gate.hold() }
            return nil
        },
        reportedPhoto: { _ in
            photoCalls += 1
            if photoWaits { await gate.hold() }
            return nil
        })
    let task = Task { try await f.load(bootstrap) }
    await gate.waitUntilEntered()
    bootstrap.invalidate()
    #expect(bootstrap.isOpening)
    await #expect(throws: GatewayCommunityFailure.busy) { try await f.load(bootstrap) }
    #expect(photoCalls == (photoWaits ? 1 : 0))
    gate.release()
    await #expect(throws: GatewayCommunityFailure.superseded) { try await task.value }
    #expect(!bootstrap.isOpening && photoCalls == (photoWaits ? 1 : 0))
    let fresh = try await f.load(bootstrap)
    #expect(bootstrap.isCurrent(fresh))
}
@Test(arguments: [false, true]) @MainActor
func communityBootstrapCancellationDoesNotReleaseSlotEarlyOrReturnMetadata(photoWaits: Bool) async throws {
    let f = try CommunityBootstrapFixture()
    let gate = CommunityBootstrapGate()
    let bootstrap = GatewayCommunityBootstrap(
        upload: { _ in
            if !photoWaits { await gate.hold() }
            return nil
        },
        reportedPhoto: { _ in
            if photoWaits { await gate.hold() }
            return nil
        })
    let task = Task { try await f.load(bootstrap) }
    await gate.waitUntilEntered()
    task.cancel()
    #expect(bootstrap.isOpening)
    await #expect(throws: GatewayCommunityFailure.busy) { try await f.load(bootstrap) }
    gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!bootstrap.isOpening)
}
@Test @MainActor func communityBootstrapChecksLifetimeAgainAfterAuthorizationGetter() async throws {
    let f = try CommunityBootstrapFixture()
    let bootstrap = GatewayCommunityBootstrap(upload: { _ in nil }, reportedPhoto: { _ in nil })
    var checks = 0
    await #expect(throws: GatewayCommunityFailure.superseded) {
        try await f.load(
            bootstrap,
            current: {
                checks += 1
                if checks == 3 { bootstrap.invalidate() }
                return true
            })
    }
    #expect(checks == 3 && !bootstrap.isOpening)
}
@Test @MainActor func communityBootstrapNewLoadAndExplicitInvalidationRevokeOldSnapshot() async throws {
    let f = try CommunityBootstrapFixture()
    let bootstrap = GatewayCommunityBootstrap(upload: { _ in nil }, reportedPhoto: { _ in nil })
    let first = try await f.load(bootstrap)
    let second = try await f.load(bootstrap)
    #expect(first.upload == nil && first.reportedPhoto == nil)
    #expect(!bootstrap.isCurrent(first) && bootstrap.isCurrent(second))
    bootstrap.invalidate()
    #expect(!bootstrap.isCurrent(second))
}
