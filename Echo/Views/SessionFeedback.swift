import EchoesCore
import SwiftUI

struct SessionFeedback: View {
    let session: CommunitySession

    var body: some View {
        if let message = session.errorMessage ?? session.statusMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Button("Zamknij komunikat") {
                    session.errorMessage = nil
                    session.statusMessage = nil
                }.font(.caption)
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
            .accessibilityElement(children: .contain)
        }
    }
}
