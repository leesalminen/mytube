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
    @State private var showingTrustedCreatorsInfo = false
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private let shelfOrder: [RankingEngine.Shelf] = [.forYou, .recent, .action, .favorites]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    heroSection
                    sharedSection
                    shelvesSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .refreshable {
                await viewModel.refresh()
            }
            .background(KidAppBackground())
            .navigationTitle("For \(appEnvironment.activeProfile.name)")
        }
        .sheet(item: $selectedVideo) { rankedVideo in
            PlayerView(rankedVideo: rankedVideo, environment: appEnvironment)
                .presentationDetents([.fraction(0.92), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                .presentationSizingPageIfAvailable()
        }
        .sheet(
            item: Binding(
                get: { viewModel.presentedRemoteVideo },
                set: { viewModel.presentedRemoteVideo = $0 }
            )
        ) { remoteVideo in
            RemoteVideoPlayerView(video: remoteVideo, environment: appEnvironment)
                .presentationDetents([.fraction(0.92), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                .presentationSizingPageIfAvailable()
        }
        .onAppear {
            viewModel.bind(to: appEnvironment)
        }
        .alert("Add Trusted Creators", isPresented: $showingTrustedCreatorsInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Ask a parent to open Parent Zone → Connections to scan a Marmot invite or approve a trusted family.")
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

    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if viewModel.sharedSections.isEmpty {
                Text("No videos from trusted families yet. Ask a parent to open Parent Zone → Connections to share or accept Marmot invites.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("From Trusted Creators")
                    .font(.title2.bold())
                if viewModel.remoteShareSummary.hasActivity {
                    remoteShareSummaryCard(summary: viewModel.remoteShareSummary)
                }
                ForEach(viewModel.sharedSections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(section.videos) { item in
                                    RemoteVideoCard(
                                        video: item,
                                        image: loadRemoteThumbnail(for: item.video),
                                        onTap: { viewModel.handleRemoteVideoTap(item) }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            addTrustedCreatorsButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func loadRemoteThumbnail(for video: RemoteVideoModel) -> UIImage? {
        guard let url = video.localThumbURL(root: appEnvironment.storagePaths.rootURL) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    @ViewBuilder
    private func remoteShareSummaryCard(summary: HomeFeedViewModel.RemoteShareSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(summary.totalCount) shared \(summary.totalCount == 1 ? "video" : "videos") available", systemImage: "tray.and.arrow.down.fill")
                .font(.headline)
            HStack(spacing: 16) {
                Label("\(summary.availableCount) queued", systemImage: "arrow.down.circle")
                Label("\(summary.downloadedCount) ready", systemImage: "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let last = summary.lastSharedAt {
                Text("Last shared \(HomeFeedView.relativeFormatter.localizedString(for: last, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var addTrustedCreatorsButton: some View {
        Button {
            showingTrustedCreatorsInfo = true
        } label: {
            Label("Add More Trusted Creators", systemImage: "person.2.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(KidPrimaryButtonStyle())
    }
}

private struct HeroCard: View {
    @EnvironmentObject private var appEnvironment: AppEnvironment
    let video: VideoModel
    let image: UIImage?
    let onTap: () -> Void

    private var appAccent: Color { appEnvironment.activeProfile.theme.kidPalette.accent }

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
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(appAccent.opacity(0.25), lineWidth: 1)
                    )

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

            PlaybackMetricRow(
                accent: appAccent,
                plays: video.playCount,
                completionRate: video.completionRate,
                replayRate: video.replayRate
            )
        }
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0.0), 1.0) * 100)
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
    @EnvironmentObject private var appEnvironment: AppEnvironment
    let video: VideoModel
    let image: UIImage?
    let onTap: () -> Void

    private var appAccent: Color { appEnvironment.activeProfile.theme.kidPalette.accent }
    private var isPending: Bool { video.approvalStatus == .pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onTap) {
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(appAccent.opacity(0.25), lineWidth: 1)
                    )

                    if video.liked {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                            .padding(8)
                    }
                    if isPending {
                        Text("Needs Approval")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.orange, in: Capsule())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(video.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 220, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
        }
    }
}

private struct RemoteVideoCard: View, Identifiable {
    @EnvironmentObject private var appEnvironment: AppEnvironment
    let video: HomeFeedViewModel.SharedRemoteVideo
    let image: UIImage?
    let onTap: () -> Void

    var id: String { video.id }

    private var appAccent: Color { appEnvironment.activeProfile.theme.kidPalette.accent }

    private var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = video.video.duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: video.video.duration) ?? "--:--"
    }

    private var status: RemoteVideoModel.Status { video.video.statusValue }

    private var statusIcon: String {
        switch status {
        case .available:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.triangle.2.circlepath"
        case .downloaded:
            return "checkmark.seal.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .revoked:
            return "exclamationmark.triangle.fill"
        case .deleted:
            return "trash.fill"
        case .blocked:
            return "hand.raised.fill"
        case .reported:
            return "exclamationmark.bubble.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .available:
            return .orange
        case .downloading:
            return .orange
        case .downloaded:
            return .green
        case .failed:
            return .red
        case .revoked:
            return .orange
        case .deleted:
            return .red
        case .blocked:
            return .red
        case .reported:
            return .orange
        }
    }

    private var actionMessage: String {
        switch status {
        case .available:
            return "Tap to download and watch."
        case .downloading:
            return "Downloading…"
        case .downloaded:
            return "Ready to watch."
        case .failed:
            return "Tap to retry download."
        case .revoked:
            return "Share revoked by sender."
        case .deleted:
            return "Video deleted by sender."
        case .blocked:
            return "This video is blocked."
        case .reported:
            return "This video is under review."
        }
    }

    private var isActionable: Bool {
        switch status {
        case .available, .failed, .downloaded:
            return true
        case .downloading, .revoked, .deleted, .blocked, .reported:
            return false
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(16 / 9, contentMode: .fill)
                                .frame(width: 240, height: 140)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.orange.opacity(0.18))
                                .frame(width: 240, height: 140)
                                .overlay(
                                    Image(systemName: "cloud.fill")
                                        .font(.system(size: 40))
                                        .foregroundStyle(.orange.opacity(0.8))
                                )
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                status == .downloaded ? Color.green.opacity(0.6) : appAccent.opacity(0.25),
                                lineWidth: 1
                            )
                    )

                    if status == .downloading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(appAccent)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.video.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("From \(video.ownerDisplayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Label(formattedDuration, systemImage: "clock")
                        Label {
                            Text(video.video.createdAt, style: .date)
                        } icon: {
                            Image(systemName: "calendar")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Label(statusLabel, systemImage: statusIcon)
                        .font(.caption)
                        .foregroundStyle(statusColor)

                    if let error = video.video.downloadError, status == .failed {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 240, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!isActionable)
        .opacity(isActionable ? 1.0 : 0.6)
    }

    private var statusLabel: String {
        switch status {
        case .available:
            return "Available"
        case .downloading:
            return "Downloading"
        case .downloaded:
            return "Downloaded"
        case .failed:
            return "Failed"
        case .revoked:
            return "Revoked"
        case .deleted:
            return "Deleted"
        case .blocked:
            return "Blocked"
        case .reported:
            return "Reported"
        }
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
        .kidCardBackground()
    }
}

private extension HomeFeedView {
    var appAccent: Color { appEnvironment.activeProfile.theme.kidPalette.accent }
}
