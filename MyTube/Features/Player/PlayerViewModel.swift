//
//  PlayerViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var video: VideoModel
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var likeCount: Int = 0
    @Published private(set) var likeRecords: [LikeRecord] = []
    @Published var likeError: String?

    var player: AVPlayer { internalPlayer }

    private let environment: AppEnvironment
    private var internalPlayer: AVPlayer
    private var timeObserver: Any?
    private var completionObserver: Any?
    private var didCompletePlayback = false
    private let logger = Logger(subsystem: "com.mytube", category: "PlayerViewModel")
    private var viewerPublicKeyHex: String?
    private var viewerChildNpub: String?
    private var viewerDisplayName: String?
    private var cancellables: Set<AnyCancellable> = []

    init(rankedVideo: RankingEngine.RankedVideo, environment: AppEnvironment) {
        self.video = rankedVideo.video
        self.environment = environment
        let url = environment.videoLibrary.videoFileURL(for: rankedVideo.video)
        self.internalPlayer = AVPlayer(url: url)
        setupBindings()
    }

    private func setupBindings() {
        updateViewerIdentity(for: environment.activeProfile)

        environment.likeStore.$likeRecords
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshLikes()
            }
            .store(in: &cancellables)

        environment.$activeProfile
            .sink { [weak self] profile in
                self?.updateViewerIdentity(for: profile)
            }
            .store(in: &cancellables)

        refreshLikes()
    }

    func onAppear() {
        attachObservers()
        play()
    }

    func onDisappear() {
        detachObservers()
        if !didCompletePlayback {
            Task {
                try? await environment.videoLibrary.recordFeedback(videoId: video.id, action: .skip)
                let update = PlaybackMetricUpdate(
                    videoId: video.id,
                    playCountDelta: 1,
                    completionRate: progress,
                    replayRate: video.replayRate,
                    liked: nil,
                    hidden: nil,
                    lastPlayedAt: Date()
                )
                if let updated = try? await environment.videoLibrary.updateMetrics(update) {
                    await MainActor.run {
                        self.video = updated
                    }
                }
            }
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func toggleLike() {
        guard let viewerKeyHex = viewerPublicKeyHex else {
            likeError = "Set up a child identity before liking videos."
            logger.error("Like toggle requested without child identity.")
            return
        }
        let targetState = !environment.likeStore.hasLiked(videoId: video.id, viewerChildNpub: viewerKeyHex)
        video.liked = targetState
        let viewerNpub = viewerChildNpub ?? viewerKeyHex
        let displayName = viewerDisplayName

        Task {
            do {
                var publishError: Error?
                if targetState {
                    await environment.likeStore.recordLike(
                        videoId: video.id,
                        viewerChildNpub: viewerKeyHex,
                        viewerDisplayName: displayName,
                        isLocalUser: true
                    )
                    do {
                        try await environment.likePublisher.publishLike(
                            videoId: video.id,
                            viewerChildNpub: viewerNpub
                        )
                    } catch {
                        publishError = error
                    }
                    try? await environment.videoLibrary.recordFeedback(videoId: video.id, action: .like)
                } else {
                    await environment.likeStore.removeLike(videoId: video.id, viewerChildNpub: viewerKeyHex)
                    do {
                        try await environment.likePublisher.publishUnlike(
                            videoId: video.id,
                            viewerChildNpub: viewerNpub
                        )
                    } catch {
                        publishError = error
                    }
                    try? await environment.videoLibrary.recordFeedback(videoId: video.id, action: .skip)
                }

                if let error = publishError {
                    if let likeError = error as? LikePublisherError, likeError == .missingVideoOwner {
                        logger.info("Skipping Nostr publish for video \(self.video.id); owner not found.")
                    } else {
                        throw error
                    }
                }

                let update = PlaybackMetricUpdate(videoId: video.id, liked: targetState)
                if let updated = try? await environment.videoLibrary.updateMetrics(update) {
                    await MainActor.run {
                        self.video = updated
                    }
                }

                await MainActor.run {
                    self.refreshLikes()
                }
            } catch {
                if targetState {
                    await environment.likeStore.removeLike(videoId: video.id, viewerChildNpub: viewerKeyHex)
                } else {
                    await environment.likeStore.recordLike(
                        videoId: video.id,
                        viewerChildNpub: viewerKeyHex,
                        viewerDisplayName: displayName,
                        isLocalUser: true
                    )
                }

                await MainActor.run {
                    self.video.liked = !targetState
                    self.refreshLikes()
                    self.likeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                logger.error("Failed to toggle like for video \(self.video.id): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clearLikeError() {
        likeError = nil
    }

    private func play() {
        internalPlayer.play()
        isPlaying = true
    }

    private func pause() {
        internalPlayer.pause()
        isPlaying = false
    }

    private func attachObservers() {
        detachObservers()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = internalPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let duration = self.internalPlayer.currentItem?.duration.seconds ?? self.video.duration
            guard duration > 0 else { return }
            self.progress = min(max(time.seconds / duration, 0), 1)
        }

        completionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: internalPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.handleCompletion()
        }
    }

    private func detachObservers() {
        if let timeObserver {
            internalPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let completionObserver {
            NotificationCenter.default.removeObserver(completionObserver)
        }
        completionObserver = nil
    }

    private func refreshLikes() {
        let records = environment.likeStore.likes(for: video.id)
        likeRecords = records
        likeCount = records.count

        if let viewerKeyHex = viewerPublicKeyHex {
            let hasLiked = environment.likeStore.hasLiked(videoId: video.id, viewerChildNpub: viewerKeyHex)
            video.liked = hasLiked
        }
    }

    private func updateViewerIdentity(for profile: ProfileModel) {
        do {
            if let identity = try environment.identityManager.childIdentity(for: profile) {
                viewerPublicKeyHex = identity.publicKeyHex.lowercased()
                if let bech32 = identity.publicKeyBech32 {
                    viewerChildNpub = bech32
                } else if let encoded = try? NIP19.encodePublicKey(identity.keyPair.publicKeyData) {
                    viewerChildNpub = encoded
                } else {
                    viewerChildNpub = identity.publicKeyHex.lowercased()
                }
                viewerDisplayName = profile.name
            } else {
                viewerPublicKeyHex = nil
                viewerChildNpub = nil
                viewerDisplayName = profile.name
            }
        } catch {
            viewerPublicKeyHex = nil
            viewerChildNpub = nil
            viewerDisplayName = profile.name
            logger.error("Unable to resolve child identity for profile \(profile.id): \(error.localizedDescription, privacy: .public)")
        }
        refreshLikes()
    }

    private func handleCompletion() {
        didCompletePlayback = true
        progress = 1.0
        Task {
            try? await environment.videoLibrary.recordFeedback(videoId: video.id, action: .replay)
            let update = PlaybackMetricUpdate(
                videoId: video.id,
                playCountDelta: 1,
                completionRate: 1.0,
                replayRate: min(1.0, video.replayRate + 0.1),
                liked: nil,
                hidden: nil,
                lastPlayedAt: Date()
            )
            if let updated = try? await environment.videoLibrary.updateMetrics(update) {
                await MainActor.run {
                    self.video = updated
                }
            }
            await MainActor.run {
                self.internalPlayer.seek(to: .zero)
                self.play()
            }
        }
    }
}
