import SwiftUI

@main
struct SatOrbitalApp: App {
    var body: some Scene {
        WindowGroup {
            OrbitScreen()
                .preferredColorScheme(.dark)
        }
    }
}
