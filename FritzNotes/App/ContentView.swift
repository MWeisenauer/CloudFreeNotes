import SwiftUI

struct ContentView: View {
    @StateObject private var store = NoteStore()

    var body: some View {
        TabView {
            NoteListView()
                .tabItem { Label("Notizen", systemImage: "note.text") }
                .environmentObject(store)
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gear") }
        }
        .environmentObject(store)
    }
}
