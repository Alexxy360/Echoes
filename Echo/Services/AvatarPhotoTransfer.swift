import CoreTransferable
import EchoesCloudKit
import UniformTypeIdentifiers

/// The provider file is consumed inside the importing callback. No provider URL or original image
/// is returned to the view, and the only retained value is AvatarPreparer's bounded JPEG pair.
// swift-format-ignore: UseSynthesizedInitializer
struct AvatarPhotoTransfer: Transferable {
    let prepared: PreparedAvatar
    // The app target defaults to MainActor; the provider constructs this value off actor.
    nonisolated init(prepared: PreparedAvatar) { self.prepared = prepared }
    nonisolated static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let task = Task.detached(priority: .utility) { try AvatarFilePreparer.prepare(received.file) }
            return try await withTaskCancellationHandler {
                try await AvatarPhotoTransfer(prepared: task.value)
            } onCancel: {
                task.cancel()
            }
        }
    }
}
