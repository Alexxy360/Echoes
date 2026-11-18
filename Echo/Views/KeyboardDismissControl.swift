import SwiftUI

/// Lives in the view's keyboard-aware safe area, with no fixed accessory-bar height.
struct KeyboardDismissControl: View {
    let identifier: String
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            Text("Ukryj klawiaturę").multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large)
        .padding(.horizontal).padding(.vertical, 8).background(.regularMaterial)
        .accessibilityIdentifier(identifier)
    }
}

#Preview("Zamknięcie klawiatury") {
    KeyboardDismissControl(identifier: "preview.keyboard.hide", dismiss: {})
}

#Preview("Największy tekst") {
    KeyboardDismissControl(identifier: "preview.keyboard.hide", dismiss: {})
        .dynamicTypeSize(.accessibility5)
}
