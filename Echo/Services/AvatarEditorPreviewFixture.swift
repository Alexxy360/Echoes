#if DEBUG
    import EchoesCloudKit
    import CryptoKit
    import Foundation
    import ImageIO
    import UIKit

    /// Synthetic fixture only. The real editor, file preparer and durable journal are unchanged.
    @MainActor final class AvatarEditorPreviewFixture {
        let host: GatewayAvatarEditorHost
        let api: AvatarEditorPreviewAPI
        let avatars: GatewayCommunityAvatarHost
        let selection: GatewayAvatarPreparation
        init(mode: String, source: any GatewayAvatarAuthorizationSource, cloudKit: CloudKitConfiguration)
            throws
        {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: .init(width: 256, height: 256), format: format)
            let bytes = renderer.jpegData(withCompressionQuality: 0.8) { context in
                UIColor.systemTeal.setFill()
                context.fill(.init(x: 0, y: 0, width: 256, height: 256))
                UIImage(systemName: "person.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: .init(x: 64, y: 48, width: 128, height: 160))
            }
            api = try AvatarEditorPreviewAPI(
                mode: mode,
                seed: mode.hasPrefix("avatar-owner-existing-") ? AvatarPreparer.prepare(bytes) : nil)
            let configuration = try GatewayConfiguration(origin: URL(string: api.origin)!)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Echoes-owner-photo-preview-" + UUID().uuidString)
            let avatars = try GatewayCommunityAvatarHost(
                api: api, configuration: configuration, cloudKit: cloudKit, authorization: source,
                cache: GatewayAvatarCache(root: root), isEnabled: { true })
            self.avatars = avatars
            let controller = try GatewayAvatarOwnerController(
                api: api, configuration: configuration,
                cloudKit: cloudKit, authorization: source, journal: GatewayAvatarUploadJournal(root: root),
                isEnabled: { true },
                presentationChanged: { [weak avatars] in avatars?.observeOwner($0, snapshot: $1) })
            host = try GatewayAvatarEditorHost(
                controller: controller, cloudKit: cloudKit, authorization: source,
                ownerPreview: GatewayAvatarOwnerPreviewHost(
                    api: api, configuration: configuration, cloudKit: cloudKit, authorization: source,
                    isEnabled: { true }), isEnabled: { true })
            selection = {
                let task = Task.detached(priority: .utility) {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "echoes-owner-synthetic-" + UUID().uuidString + ".jpg")
                    try bytes.write(to: file)
                    defer { try? FileManager.default.removeItem(at: file) }
                    return try AvatarFilePreparer.prepare(file)
                }
                return try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            }
        }
    }
    actor AvatarEditorPreviewAPI: GatewayAvatarMutationAPI, GatewayAvatarReadAPI, GatewayAvatarOwnerPreviewAPI
    {
        nonisolated let origin = "https://community-preview.example.invalid"
        private let approved: Bool
        private var loseUpload: Bool
        private var losePublication: Bool
        private var delayed: Bool
        private var waiting: CheckedContinuation<Void, Never>?
        private var states: [String: GatewayAvatarOwnerSnapshot] = [:]
        private var photos: [String: PreparedAvatar] = [:]
        private var selectedOwner = "11111111-1111-4111-8111-111111111111"
        func selectOwner(_ value: String) { selectedOwner = value }
        init(mode: String, seed: PreparedAvatar? = nil) throws {
            approved =
                mode == "avatar-owner-approved" || mode == "avatar-owner-no-location"
                || mode == "avatar-owner-publish-lost" || mode == "avatar-owner-existing-approved"
            loseUpload = mode == "avatar-owner-lost"
            losePublication = mode == "avatar-owner-publish-lost"
            delayed = mode == "avatar-owner-delayed"
            if let seed {
                photos[selectedOwner] = seed
                states[selectedOwner] = try snapshot(
                    generation: 1, request: UUID().uuidString.lowercased(),
                    version: UUID().uuidString.lowercased(), status: approved ? .approved : .pendingReview)
            }
        }
        func release() {
            delayed = false
            waiting?.resume()
            waiting = nil
        }
        nonisolated private func snapshot(
            generation: Int = 0, request: String? = nil, version: String? = nil,
            status: GatewayAvatarOwnerStatus = .none
        ) throws -> GatewayAvatarOwnerSnapshot {
            try .init(
                data: JSONSerialization.data(withJSONObject: [
                    "protocolVersion": 1, "generation": generation, "requestID": request as Any? ?? NSNull(),
                    "versionID": version as Any? ?? NSNull(), "status": status.rawValue,
                    "publishedVersionID": status == .published ? version as Any? ?? NSNull() : NSNull(),
                    "reviewRevision": version == nil ? NSNull() : "6c000000-0000-4000-8000-000000000099",
                ]))
        }
        func perform(_ action: GatewayAvatarMutation, token: GatewaySecret) async throws
            -> GatewayAvatarOwnerSnapshot
        {
            let owner = selectedOwner
            let old = try states[owner] ?? snapshot()
            let value: GatewayAvatarOwnerSnapshot
            switch action {
            case .status: return old
            case .upload(let intent, let image):
                guard old.generation == intent.expectedGeneration || old.requestID == intent.requestID else {
                    throw GatewayAvatarMutationFailure.stale
                }
                value = try snapshot(
                    generation: intent.expectedGeneration + 1, request: intent.requestID,
                    version: intent.versionID, status: approved ? .approved : .pendingReview)
                photos[owner] = try AvatarPreparer.prepare(image)
            case .recover(let id):
                guard old.requestID == id else { throw GatewayAvatarMutationFailure.stale }
                return old
            case .publish(let publication):
                let id = publication.requestID
                guard publication.matches(old) else { throw GatewayAvatarMutationFailure.stale }
                guard old.requestID == id, old.status == .approved || old.status == .published else {
                    throw GatewayAvatarMutationFailure.pending
                }
                value = try snapshot(
                    generation: old.generation, request: id, version: old.versionID, status: .published)
            case .clear(let id, let generation):
                guard old.generation == generation || old.requestID == id && old.generation == generation + 1
                else { throw GatewayAvatarMutationFailure.stale }
                value = try snapshot(generation: generation + 1, request: id)
            }
            states[owner] = value
            if case .publish = action, losePublication {
                losePublication = false
                throw GatewayAvatarMutationFailure.unavailable
            }
            if action.isUploadForPreview {
                if delayed { await withCheckedContinuation { waiting = $0 } }
                if loseUpload {
                    loseUpload = false
                    throw GatewayAvatarMutationFailure.unavailable
                }
            }
            return value
        }
        func preview(_ query: GatewayAvatarOwnerPreviewQuery, token: GatewaySecret) async throws
            -> GatewayAvatarOwnerPreview
        {
            let owner = selectedOwner
            guard query.ownerID == owner, let state = states[owner], state.status == .approved,
                query.selection.matches(state), let photo = photos[owner],
                let source = CGImageSourceCreateWithData(photo.image as CFData, nil),
                let fields = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = fields[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = fields[kCGImagePropertyPixelHeight] as? NSNumber
            else { throw GatewayAvatarFailure.notFound }
            let manifest: [String: Any] = [
                "schemaVersion": 1, "ownerID": owner, "versionID": query.selection.versionID,
                "variant": "image", "byteCount": photo.image.count, "width": width, "height": height,
                "sha256": SHA256.hash(data: photo.image).map { String(format: "%02x", $0) }.joined(),
            ]
            let proof: [String: Any] = [
                "schemaVersion": 1, "requestID": query.selection.requestID,
                "versionID": query.selection.versionID,
                "generation": query.selection.generation, "reviewRevision": query.selection.reviewRevision,
            ]
            let response = GatewayAvatarHTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "image/jpeg", "Content-Length": String(photo.image.count),
                    "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff",
                    "X-Echoes-Avatar-Manifest": String(
                        decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self),
                    "X-Echoes-Avatar-Selection": String(
                        decoding: try JSONSerialization.data(withJSONObject: proof), as: UTF8.self),
                ], body: photo.image)
            return try await GatewayAvatarOwnerPreviewHTTPClient(
                configuration: .init(origin: URL(string: origin)!),
                transport: AvatarEditorOwnerPreviewTransport(response: response), isEnabled: { true }
            ).preview(query, token: token)
        }
        func read(_ query: GatewayAvatarQuery, token: GatewaySecret) async throws -> GatewayAvatarReply {
            let owner = query.reference.ownerID
            guard owner == selectedOwner, let state = states[owner], state.status == .published,
                state.publishedVersionID == query.reference.versionID, let photo = photos[owner]
            else { throw GatewayAvatarFailure.notFound }
            let bytes = query.variant == .image ? photo.image : photo.thumbnail
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                let fields = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = fields[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = fields[kCGImagePropertyPixelHeight] as? NSNumber
            else { throw GatewayAvatarFailure.invalidResponse }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let manifest = try AvatarManifest(
                data: JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 1, "ownerID": owner, "versionID": query.reference.versionID,
                    "variant": query.variant.rawValue, "byteCount": bytes.count, "sha256": digest,
                    "width": width, "height": height,
                ]), expected: query.reference, variant: query.variant)
            return query.knownSHA256 == digest
                ? .revalidated(manifest: manifest) : .downloaded(manifest: manifest, bytes: bytes)
        }
    }
    private actor AvatarEditorOwnerPreviewTransport: GatewayAvatarOwnerPreviewTransport {
        let response: GatewayAvatarHTTPResponse
        init(response: GatewayAvatarHTTPResponse) { self.response = response }
        func send(_ request: URLRequest, query: GatewayAvatarOwnerPreviewQuery) async throws
            -> GatewayAvatarHTTPResponse
        { response }
    }
    extension GatewayAvatarMutation {
        nonisolated fileprivate var isUploadForPreview: Bool {
            if case .upload = self { true } else { false }
        }
    }
#endif
