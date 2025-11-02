//
//  RemoteVideoPlayerView.swift
//  MyTube
//
//  Created by Codex on 11/13/25.
//

import AVKit
import SwiftUI

struct RemoteVideoPlayerView: View {
    let video: HomeFeedViewModel.SharedRemoteVideo
    let environment: AppEnvironment

    @State private var player: AVPlayer?
    @State private var playbackError: String?

    private var durationFormatter: DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = video.video.duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                if let player {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(radius: 8)
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.orange.opacity(0.2))
                        .frame(maxWidth: .infinity)
                        .frame(height: 320)
                        .overlay(
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.orange)
                                Text(playbackError ?? "Preparing video…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(video.video.title)
                    .font(.title2.bold())
                Text("Shared by \(video.ownerDisplayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Label(durationFormatter.string(from: video.video.duration) ?? "--:--", systemImage: "clock")
                    Label {
                        Text(video.video.createdAt, style: .date)
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .background(Color(.systemGroupedBackground))
        .task {
            await preparePlayerIfNeeded()
        }
        .onDisappear {
            player?.pause()
        }
    }

    @MainActor
    private func setPlaybackError(_ message: String) {
        playbackError = message
    }

    private func preparePlayerIfNeeded() async {
        if player != nil { return }

        guard let mediaURL = video.video.localMediaURL(root: environment.storagePaths.rootURL) else {
            await MainActor.run {
                setPlaybackError("Video file is missing on this device.")
            }
            return
        }

        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            await MainActor.run {
                setPlaybackError("Video file is missing on this device.")
            }
            return
        }

        let newPlayer = AVPlayer(url: mediaURL)
        await MainActor.run {
            self.player = newPlayer
            self.player?.play()
        }
    }
}
