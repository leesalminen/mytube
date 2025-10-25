//
//  HomeFeedView.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import SwiftUI
import UIKit

struct HomeFeedView: View {
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @StateObject private var viewModel = HomeFeedViewModel()
    @State private var selectedVideo: RankingEngine.RankedVideo?

    private let shelfOrder: [RankingEngine.Shelf] = [.forYou, .recent, .calm, .action, .favorites]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    heroSection
                    shelvesSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("For \(appEnvironment.activeProfile.name)")
        }
        .sheet(item: $selectedVideo) { rankedVideo in
            PlayerView(rankedVideo: rankedVideo, environment: appEnvironment)
                .presentationDetents([.fraction(0.92), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                .presentationSizing(.page)
        }
        .onAppear {
            viewModel.bind(to: appEnvironment)
        }
    }

    private var heroSection: some View {
        Group {
            if let hero = viewModel.hero {
                HeroCard(
                    video: hero.video,
                    image: loadThumbnail(for: hero.video)
                ) {
                    selectedVideo = hero
                }
            } else {
                EmptyStateView()
            }
        }
    }

    private var shelvesSection: some View {
        ForEach(shelfOrder, id: \.self) { shelf in
            if shelf == .forYou {
                if let videos = viewModel.shelves[.forYou], videos.count > 1 {
                    ShelfView(
                        title: shelf.rawValue,
                        videos: Array(videos.dropFirst()),
                        onSelect: { selectedVideo = $0 },
                        thumbnailLoader: loadThumbnail
                    )
                }
            } else if let videos = viewModel.shelves[shelf], !videos.isEmpty {
                ShelfView(
                    title: shelf.rawValue,
                    videos: videos,
                    onSelect: { selectedVideo = $0 },
                    thumbnailLoader: loadThumbnail
                )
            }
        }
    }

    private func loadThumbnail(for video: VideoModel) -> UIImage? {
        let url = appEnvironment.videoLibrary.thumbnailFileURL(for: video)
        return UIImage(contentsOfFile: url.path)
    }
}

private struct HeroCard: View {
    let video: VideoModel
    let image: UIImage?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onTap) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(16 / 9, contentMode: .fill)
                        } else {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.purple.opacity(0.2))
                                .overlay(
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 72))
                                        .foregroundStyle(.white.opacity(0.8))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hero Pick")
                            .font(.caption)
                            .bold()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThickMaterial, in: Capsule())
                        Text(video.title)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 8)
                        Text(video.createdAt, style: .date)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(24)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 24) {
                MetricChip(label: "Plays", value: "\(video.playCount)")
                MetricChip(label: "Completion", value: percentage(video.completionRate))
                MetricChip(label: "Replay", value: percentage(video.replayRate))
            }
        }
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0.0), 1.0) * 100)
    }
}

private struct MetricChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
    }
}

private struct ShelfView: View {
    let title: String
    let videos: [RankingEngine.RankedVideo]
    let onSelect: (RankingEngine.RankedVideo) -> Void
    let thumbnailLoader: (VideoModel) -> UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(videos) { rankedVideo in
                        VideoCard(
                            video: rankedVideo.video,
                            image: thumbnailLoader(rankedVideo.video),
                            onTap: { onSelect(rankedVideo) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct VideoCard: View {
    let video: VideoModel
    let image: UIImage?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(16 / 9, contentMode: .fill)
                        } else {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.blue.opacity(0.2))
                                .overlay(
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.blue.opacity(0.6))
                                )
                        }
                    }
                    .frame(width: 220, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if video.liked {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                            .padding(8)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(video.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 220, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Let’s create your first memory")
                .font(.title3.bold())
            Text("Record something magical to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(48)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        )
    }
}
