import SwiftUI

@main
struct GreenSightApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var mapModel = MapModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(mapModel)
                .preferredColorScheme(.dark)
        }
    }
}
