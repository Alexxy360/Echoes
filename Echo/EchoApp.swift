import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFunctions
import SwiftUI

@main
struct EchoApp: App {
    @State private var services: AppServices

    init() {
        #if DEBUG
            if ProcessInfo.processInfo.environment["ECHOES_DEMO_MODE"] == "1" {
                _services = State(initialValue: AppServices.preview())
                return
            }
        #endif
        Self.configureFirebase()
        _services = State(initialValue: AppServices())
    }

    var body: some Scene { WindowGroup { ContentView(services: services) } }

    private static func configureFirebase() {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
            let options = FirebaseOptions(contentsOfFile: path)
        else { return }
        AppCheck.setAppCheckProviderFactory(EchoesAppCheckFactory())
        #if DEBUG
            let emulator = ProcessInfo.processInfo.environment["ECHOES_USE_EMULATORS"] == "1"
            if emulator { options.projectID = "demo-echoes" }
        #endif
        FirebaseApp.configure(options: options)
        #if DEBUG
            if emulator {
                let host = ProcessInfo.processInfo.environment["ECHOES_EMULATOR_HOST"] ?? "127.0.0.1"
                Auth.auth().useEmulator(withHost: host, port: 9099)
                Functions.functions(region: "europe-west1").useEmulator(withHost: host, port: 5001)
            }
        #endif
    }
}

private final class EchoesAppCheckFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if DEBUG
            return AppCheckDebugProvider(app: app)
        #else
            return AppAttestProvider(app: app) ?? DeviceCheckProvider(app: app)
        #endif
    }
}
