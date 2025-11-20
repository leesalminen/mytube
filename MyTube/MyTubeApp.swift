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
        guard url.scheme?.caseInsensitiveCompare("tubestr") == .orderedSame else { return }
        
        // Handle follow-invite links
        if url.host?.caseInsensitiveCompare("follow-invite") == .orderedSame {
            if let invite = ParentZoneViewModel.FollowInvite.decode(from: url.absoluteString) {
                // Store the invite for the parent zone to process
                NotificationCenter.default.post(
                    name: NSNotification.Name("TubestrFollowInviteReceived"),
                    object: nil,
                    userInfo: ["invite": invite]
                )
            }
        }
    }
}
