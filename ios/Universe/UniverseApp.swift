import SwiftUI

@main
struct UniverseApp: App {
    init() { DiagnosticsLog.shared.start() }

    var body: some Scene {
        WindowGroup {
            GameView()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .background(Color("LaunchBackground"))
        }
    }
}
