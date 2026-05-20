//
//  FritzNotesApp.swift
//  FritzNotes
//
//  Created by Markus Weisenauer on 20.05.26.
//

import SwiftUI
import CoreData

@main
struct FritzNotesApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
