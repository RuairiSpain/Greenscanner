import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ARScreen()
                .tabItem { Label("Read", systemImage: "viewfinder") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .tint(.mint)
    }
}
