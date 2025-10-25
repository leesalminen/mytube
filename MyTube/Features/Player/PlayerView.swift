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

    init(rankedVideo: RankingEngine.RankedVideo, environment: AppEnvironment) {
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
                    ControlButton(systemName: viewModel.video.liked ? "heart.fill" : "heart") {
                        viewModel.toggleLike()
                    }
                    ControlButton(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill") {
                        viewModel.togglePlayPause()
                    }
                    ControlButton(systemName: "xmark") {
                        dismiss()
                    }
                }
                .font(.title2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(32)
        .background(Color(.systemGroupedBackground))
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }
}

private struct ControlButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 56, height: 56)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
