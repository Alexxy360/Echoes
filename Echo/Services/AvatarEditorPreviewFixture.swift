#if DEBUG
    import EchoesCloudKit
    import Foundation
    import UIKit

    /// Synthetic fixture only. The real editor, file preparer and durable journal are unchanged.
    @MainActor final class AvatarEditorPreviewFixture {
        let host: GatewayAvatarEditorHost
        let api: AvatarEditorPreviewAPI
        let selection: @Sendable () async throws -> PreparedAvatar
        init(mode: String, source: any GatewayAvatarAuthorizationSource, cloudKit: CloudKitConfiguration)
            throws
        {
            api = AvatarEditorPreviewAPI(mode: mode)
            let configuration = try GatewayConfiguration(origin: URL(string: api.origin)!)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Echoes-owner-photo-preview-" + UUID().uuidString)
            let controller = try GatewayAvatarOwnerController(
                api: api, configuration: configuration,
                cloudKit: cloudKit, authorization: source, journal: GatewayAvatarUploadJournal(root: root),
                isEnabled: { true })
            host = try GatewayAvatarEditorHost(
                controller: controller, cloudKit: cloudKit, authorization: source, isEnabled: { true })
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
    actor AvatarEditorPreviewAPI: GatewayAvatarMutationAPI {
        nonisolated let origin = "https://community-preview.example.invalid"
        private let approved: Bool
        private var loseUpload: Bool
        private var delayed: Bool
        private var waiting: CheckedContinuation<Void, Never>?
        private var states: [String: GatewayAvatarOwnerSnapshot] = [:]
        private var selectedOwner = "11111111-1111-4111-8111-111111111111"
        func selectOwner(_ value: String) { selectedOwner = value }
        init(mode: String) {
            approved = mode == "avatar-owner-approved"
            loseUpload = mode == "avatar-owner-lost"
            delayed = mode == "avatar-owner-delayed"
        }
        func release() {
            delayed = false
            waiting?.resume()
            waiting = nil
        }
        private func snapshot(
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
            case .upload(let intent, _):
                guard old.generation == intent.expectedGeneration || old.requestID == intent.requestID else {
                    throw GatewayAvatarMutationFailure.stale
                }
                value = try snapshot(
                    generation: intent.expectedGeneration + 1, request: intent.requestID,
                    version: intent.versionID, status: approved ? .approved : .pendingReview)
            case .recover(let id):
                guard old.requestID == id else { throw GatewayAvatarMutationFailure.stale }
                return old
            case .publish(let id):
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
            if action.isUploadForPreview {
                if delayed { await withCheckedContinuation { waiting = $0 } }
                if loseUpload {
                    loseUpload = false
                    throw GatewayAvatarMutationFailure.unavailable
                }
            }
            return value
        }
    }
    extension GatewayAvatarMutation {
        fileprivate var isUploadForPreview: Bool { if case .upload = self { true } else { false } }
    }
#endif
