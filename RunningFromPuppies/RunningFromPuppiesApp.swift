//
//  RunningFromPuppiesApp.swift
//  RunningFromPuppies
//
//  Created by David Wilcox on 12/17/25.
//

import SwiftUI
import CoreData

@main
struct RunningFromPuppiesApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
