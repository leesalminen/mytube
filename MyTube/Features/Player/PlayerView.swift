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
    @State private var showingReportSheet = false
    @State private var showingPublishPIN = false

    init(rankedVideo: RankingEngine.RankedVideo, environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(wrappedValue: PlayerViewModel(rankedVideo: rankedVideo, environment: environment))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack(spacing: 12) {
                    if viewModel.shouldShowPublishAction {
                        Button {
                            showingPublishPIN = true
                        } label: {
                            HStack(spacing: 8) {
                                if viewModel.isPublishing {
                                    ProgressView()
                                        .tint(Color.accentColor)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text("Publish")
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                        .disabled(viewModel.isPublishing)
                    }
                    Spacer()
                    ReportButtonChip {
                        viewModel.reportError = nil
                        showingReportSheet = true
                    }
                }

                VideoPlayer(player: viewModel.player)
                    .frame(maxWidth: .infinity)
                    .frame(height: 540)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.video.title)
                        .font(.title.bold())
                    ProgressView(value: viewModel.progress)
                        .tint(Color.accentColor)

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
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 48)
        }
        .background(KidAppBackground())
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .sheet(isPresented: $showingReportSheet) {
            ReportAbuseSheet(
                allowsRelationshipActions: false,
                isSubmitting: viewModel.isReporting,
                errorMessage: Binding(
                    get: { viewModel.reportError },
                    set: { viewModel.reportError = $0 }
                ),
                onSubmit: { reason, note, action in
                    Task { await viewModel.reportVideo(reason: reason, note: note, action: action) }
                },
                onCancel: {
                    viewModel.resetReportState()
                    showingReportSheet = false
                }
            )
            .presentationDetents([.medium, .large])
        }
        .onChange(of: viewModel.reportSuccess) { success in
            if success {
                showingReportSheet = false
                dismiss()
                viewModel.resetReportState()
            }
        }
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
        .sheet(isPresented: $showingPublishPIN) {
            PINPromptView(title: "Publish Video") { pin in
                try await viewModel.publishPendingVideo(pin: pin)
            }
        }
    }
}
