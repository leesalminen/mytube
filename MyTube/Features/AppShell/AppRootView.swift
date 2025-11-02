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
        Group {
            switch appEnvironment.onboardingState {
            case .needsParentIdentity:
                OnboardingFlowView(environment: appEnvironment)
            case .ready:
                NavigationSplitView {
                    SidebarView(selection: $selection)
                } detail: {
                    detailView(for: selection ?? .home)
                }
            }
        }
        .tint(appEnvironment.activeProfile.theme.kidPalette.accent)
        .background(KidAppBackground())
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

                    Picker(
                        "Theme",
                        selection: Binding(
                            get: { appEnvironment.activeProfile.theme },
                            set: { newTheme in
                                applyTheme(newTheme)
                            }
                        )
                    ) {
                        ForEach(ThemeDescriptor.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .kidCardBackground()
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Tubestr")
        .scrollContentBackground(.hidden)
    }
}

private extension SidebarView {
    func applyTheme(_ theme: ThemeDescriptor) {
        var updated = appEnvironment.activeProfile
        updated.theme = theme
        do {
            try appEnvironment.profileStore.updateProfile(updated)
            appEnvironment.switchProfile(updated)
        } catch {
            assertionFailure("Failed to update profile theme: \(error)")
        }
    }
}
