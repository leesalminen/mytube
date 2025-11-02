//
//  RemoteVideoPlayerView.swift
//  MyTube
//
//  Created by Codex on 11/13/25.
//

import AVKit
import Combine
import SwiftUI

struct RemoteVideoPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let video: HomeFeedViewModel.SharedRemoteVideo
    let environment: AppEnvironment

    @StateObject private var viewModel: RemoteVideoPlayerViewModel
    @State private var showingReportSheet = false

    init(video: HomeFeedViewModel.SharedRemoteVideo, environment: AppEnvironment) {
        self.video = video
        self.environment = environment
        _viewModel = StateObject(wrappedValue: RemoteVideoPlayerViewModel(video: video, environment: environment))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Spacer()
                Button {
                    viewModel.reportError = nil
                    showingReportSheet = true
                } label: {
                    Label("Report", systemImage: "hand.raised.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.red)
                        .padding(8)
                }
                .accessibilityLabel("Report or block this video")
            }

            Group {
                if let player = viewModel.player {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.orange.opacity(0.2))
                        .frame(maxWidth: .infinity)
                        .frame(height: 360)
                        .overlay(
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.orange)
                                Text(viewModel.playbackError ?? "Preparing video…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        )
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Text(video.video.title)
                    .font(.title.bold())
                ProgressView(value: viewModel.progress)
                    .tint(.accentColor)

                HStack(spacing: 24) {
                    PlaybackControlButton(systemName: viewModel.isLiked ? "heart.fill" : "heart") {
                        viewModel.toggleLike()
                    }
                    PlaybackControlButton(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill") {
                        viewModel.togglePlayPause()
                    }
                    PlaybackControlButton(systemName: "xmark") {
                        viewModel.dismiss()
                        dismiss()
                    }
                }
                .font(.title2)

                PlaybackLikeSummaryView(
                    likeCount: viewModel.likeCount,
                    records: viewModel.likeRecords
                )

                PlaybackMetricRow(
                    accent: environment.activeProfile.theme.kidPalette.accent,
                    plays: nil,
                    completionRate: nil,
                    replayRate: nil
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Shared by \(video.ownerDisplayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Label(viewModel.formattedDuration, systemImage: "clock")
                        Label {
                            Text(video.video.createdAt, style: .date)
                        } icon: {
                            Image(systemName: "calendar")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(24)
        .background(KidAppBackground())
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .alert(
            "Couldn't update like",
            isPresented: Binding(
                get: { viewModel.likeError != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.clearLikeError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.clearLikeError()
            }
        } message: {
            Text(viewModel.likeError ?? "Something went wrong.")
        }
        .sheet(isPresented: $showingReportSheet) {
            ReportAbuseSheet(
                isSubmitting: viewModel.isReporting,
                errorMessage: Binding(
                    get: { viewModel.reportError },
                    set: { viewModel.reportError = $0 }
                ),
                onSubmit: { reason, note, action in
                    Task { await viewModel.reportVideo(reason: reason, note: note, action: action) }
                },
                onCancel: {
                    viewModel.reportError = nil
                    showingReportSheet = false
                }
            )
            .presentationDetents([.medium, .large])
        }
        .onChange(of: viewModel.reportSuccess) { success in
            if success {
                showingReportSheet = false
                viewModel.dismiss()
                dismiss()
            }
        }
    }
}

@MainActor
final class RemoteVideoPlayerViewModel: ObservableObject {
    @Published private(set) var video: HomeFeedViewModel.SharedRemoteVideo
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLiked = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var likeCount: Int = 0
    @Published private(set) var likeRecords: [LikeRecord] = []
    @Published var likeError: String?
    @Published var playbackError: String?
    @Published var isReporting = false
    @Published var reportError: String?
    @Published var reportSuccess = false

    let formattedDuration: String

    private let environment: AppEnvironment
    private var viewerPublicKeyHex: String?
    private var viewerChildNpub: String?
    private var viewerDisplayName: String?
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var isDismissed = false

    private var videoId: UUID? {
        UUID(uuidString: video.video.id)
    }

    init(video: HomeFeedViewModel.SharedRemoteVideo, environment: AppEnvironment) {
        self.video = video
        self.environment = environment
        self.formattedDuration = RemoteVideoPlayerViewModel.makeDurationFormatter(duration: video.video.duration)
        setupBindings()
        refreshLikes()
    }

    func onAppear() {
        Task { await preparePlayerIfNeeded() }
    }

    func onDisappear() {
        guard !isDismissed else { return }
        cleanupPlayer()
    }

    func dismiss() {
        isDismissed = true
        reportSuccess = false
        cleanupPlayer()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func toggleLike() {
        guard let viewerKeyHex = viewerPublicKeyHex else {
            likeError = "Set up a child identity before liking videos."
            return
        }
        guard let videoId else {
            likeError = "This shared video can't be liked right now."
            return
        }

        let targetState = !environment.likeStore.hasLiked(videoId: videoId, viewerChildNpub: viewerKeyHex)
        isLiked = targetState

        let viewerNpub = viewerChildNpub ?? viewerKeyHex
        let displayName = viewerDisplayName

        Task {
            do {
                if targetState {
                    await environment.likeStore.recordLike(
                        videoId: videoId,
                        viewerChildNpub: viewerKeyHex,
                        viewerDisplayName: displayName,
                        isLocalUser: true
                    )
                    try await environment.likePublisher.publishLike(
                        videoId: videoId,
                        viewerChildNpub: viewerNpub
                    )
                } else {
                    await environment.likeStore.removeLike(videoId: videoId, viewerChildNpub: viewerKeyHex)
                    try await environment.likePublisher.publishUnlike(
                        videoId: videoId,
                        viewerChildNpub: viewerNpub
                    )
                }

                await MainActor.run {
                    self.refreshLikes()
                }
            } catch {
                if targetState {
                    await environment.likeStore.removeLike(videoId: videoId, viewerChildNpub: viewerKeyHex)
                } else {
                    await environment.likeStore.recordLike(
                        videoId: videoId,
                        viewerChildNpub: viewerKeyHex,
                        viewerDisplayName: displayName,
                        isLocalUser: true
                    )
                }

                await MainActor.run {
                    self.isLiked = !targetState
                    self.refreshLikes()
                    self.likeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    func clearLikeError() {
        likeError = nil
    }

    func reportVideo(
        reason: ReportReason,
        note: String?,
        action: ReportAction
    ) async {
        guard !isReporting else { return }
        isReporting = true

        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote

        do {
            _ = try await environment.reportCoordinator.submitReport(
                videoId: video.video.id,
                subjectChild: video.video.ownerChild,
                reason: reason,
                note: finalNote,
                action: action
            )
            reportSuccess = true
            isReporting = false
        } catch {
            reportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isReporting = false
        }
    }

    private func setupBindings() {
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

        updateViewerIdentity(for: environment.activeProfile)
    }

    private func refreshLikes() {
        guard let videoId else {
            likeCount = 0
            likeRecords = []
            isLiked = false
            return
        }

        let records = environment.likeStore.likes(for: videoId)
        likeRecords = records
        likeCount = records.count

        if let viewerKeyHex = viewerPublicKeyHex {
            isLiked = environment.likeStore.hasLiked(videoId: videoId, viewerChildNpub: viewerKeyHex)
        } else {
            isLiked = false
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
        }
        refreshLikes()
    }

    private func preparePlayerIfNeeded() async {
        guard player == nil else { return }

        guard let mediaURL = video.video.localMediaURL(root: environment.storagePaths.rootURL) else {
            playbackError = "Video file is missing on this device."
            return
        }

        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            playbackError = "Video file is missing on this device."
            return
        }

        let newPlayer = AVPlayer(url: mediaURL)
        player = newPlayer
        attachTimeObserver()
        newPlayer.play()
        isPlaying = true
    }

    private func attachTimeObserver() {
        detachTimeObserver()
        guard let player else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let duration = player.currentItem?.duration.seconds ?? video.video.duration
            guard duration > 0 else { return }
            self.progress = min(max(time.seconds / duration, 0), 1)
        }
    }

    private func detachTimeObserver() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func cleanupPlayer() {
        detachTimeObserver()
        player?.pause()
        player = nil
        isPlaying = false
    }

    private static func makeDurationFormatter(duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "--:--"
    }
}
