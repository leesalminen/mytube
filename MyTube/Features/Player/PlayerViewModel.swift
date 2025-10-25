//
//  PlayerViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVFoundation
import Foundation

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var video: VideoModel
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0

    var player: AVPlayer { internalPlayer }

    private let environment: AppEnvironment
    private var internalPlayer: AVPlayer
    private var timeObserver: Any?
    private var completionObserver: Any?
    private var didCompletePlayback = false

    init(rankedVideo: RankingEngine.RankedVideo, environment: AppEnvironment) {
        self.video = rankedVideo.video
        self.environment = environment
        let url = environment.videoLibrary.videoFileURL(for: rankedVideo.video)
        self.internalPlayer = AVPlayer(url: url)
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
        let newValue = !video.liked
        video.liked = newValue
        Task {
            let update = PlaybackMetricUpdate(videoId: video.id, liked: newValue)
            if let updated = try? await environment.videoLibrary.updateMetrics(update) {
                await MainActor.run {
                    self.video = updated
                }
            }
            try? await environment.videoLibrary.recordFeedback(videoId: video.id, action: newValue ? .like : .skip)
        }
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
