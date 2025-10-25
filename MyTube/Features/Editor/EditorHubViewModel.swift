//
//  EditorHubViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Combine
import Foundation

@MainActor
final class EditorHubViewModel: ObservableObject {
    @Published private(set) var videos: [VideoModel] = []
    @Published private(set) var errorMessage: String?

    private let environment: AppEnvironment
    private var cancellables: Set<AnyCancellable> = []

    init(environment: AppEnvironment) {
        self.environment = environment
        observeProfileChanges()
        loadVideos()
    }

    func loadVideos() {
        do {
            videos = try environment.videoLibrary.fetchVideos(profileId: environment.activeProfile.id, includeHidden: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func observeProfileChanges() {
        environment.$activeProfile
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.loadVideos()
            }
            .store(in: &cancellables)
    }
}
