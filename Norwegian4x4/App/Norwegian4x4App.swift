import FourByFourCore
import SwiftUI

@main
struct Norwegian4x4App: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { url in
                    _ = model.music.handleOpenURL(url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.workout.scenePhaseChanged(isActive: true)
                model.music.appBecameActive()
            case .background:
                model.workout.scenePhaseChanged(isActive: false)
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
