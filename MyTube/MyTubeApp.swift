//
//  MyTubeApp.swift
//  MyTube
//
//  Created by Lee Salminen on 10/24/25.
//

import SwiftUI

@main
struct MyTubeApp: App {
    @StateObject private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(environment)
                .environment(\.managedObjectContext, environment.persistence.viewContext)
                .preferredColorScheme(.light)
        }
    }
}
