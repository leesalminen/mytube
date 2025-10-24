//
//  MyTubeApp.swift
//  MyTube
//
//  Created by Lee Salminen on 10/24/25.
//

import SwiftUI

@main
struct MyTubeApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
