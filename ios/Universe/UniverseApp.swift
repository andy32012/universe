import SwiftUI

@main
struct UniverseApp: App {
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
