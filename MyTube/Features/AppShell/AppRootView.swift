//
//  AppRootView.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @State private var selection: Route? = .home

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            detailView(for: selection ?? .home)
        }
    }

    @ViewBuilder
    private func detailView(for route: Route) -> some View {
        switch route {
        case .home:
            HomeFeedView()
        case .capture:
            CaptureView(environment: appEnvironment)
        case .editor:
            EditorHubView(environment: appEnvironment)
        case .parentZone:
            ParentZoneView(environment: appEnvironment)
        }
    }

    enum Route: Hashable {
        case home
        case capture
        case editor
        case parentZone
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Binding var selection: AppRootView.Route?

    var body: some View {
        List(selection: $selection) {
            Section("Browse") {
                NavigationLink(value: AppRootView.Route.home) {
                    Label("Home", systemImage: "house.fill")
                }
                NavigationLink(value: AppRootView.Route.capture) {
                    Label("Capture", systemImage: "video.badge.plus")
                }
                NavigationLink(value: AppRootView.Route.editor) {
                    Label("Editor", systemImage: "wand.and.stars")
                }
                NavigationLink(value: AppRootView.Route.parentZone) {
                    Label("Parent Zone", systemImage: "lock.shield")
                }
            }

            Section("Active Profile") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appEnvironment.activeProfile.name)
                        .font(.headline)
                    Text("Theme: \(appEnvironment.activeProfile.theme.rawValue.capitalized)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("MyTube")
    }
}
