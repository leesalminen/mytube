//
//  PlayerView.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVKit
import SwiftUI

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: PlayerViewModel
    private let environment: AppEnvironment

    init(rankedVideo: RankingEngine.RankedVideo, environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(wrappedValue: PlayerViewModel(rankedVideo: rankedVideo, environment: environment))
    }

    var body: some View {
        VStack(spacing: 24) {
            VideoPlayer(player: viewModel.player)
                .frame(maxHeight: 480)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 16) {
                Text(viewModel.video.title)
                    .font(.title.bold())
                ProgressView(value: viewModel.progress)
                    .tint(.accentColor)

                HStack(spacing: 24) {
                    PlaybackControlButton(systemName: viewModel.video.liked ? "heart.fill" : "heart") {
                        viewModel.toggleLike()
                    }
                    PlaybackControlButton(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill") {
                        viewModel.togglePlayPause()
                    }
                    PlaybackControlButton(systemName: "xmark") {
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
                    plays: viewModel.video.playCount,
                    completionRate: viewModel.video.completionRate,
                    replayRate: viewModel.video.replayRate
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(32)
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
    }
}
