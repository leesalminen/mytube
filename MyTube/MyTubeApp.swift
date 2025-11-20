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
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }
    
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "tubestr" || url.scheme == "mytube" else { return }
        
        // Store the URL and trigger navigation to Parent Zone
        environment.pendingDeepLink = url
        
        // The URL will be handled by ParentZoneView when it appears
        // We could add a more sophisticated routing mechanism here if needed
        print("🔗 Deep link received: \(url.absoluteString)")
    }
}
