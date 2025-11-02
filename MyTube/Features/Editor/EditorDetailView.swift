//
//  EditorDetailView.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVKit
import SwiftUI

struct EditorDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @StateObject private var viewModel: EditorDetailViewModel

    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var wasPlayingBeforeScrub = false
    @State private var playhead: Double = 0
    @State private var timeObserver: Any?
    @State private var showDeleteConfirm = false
    @State private var isScrubbing = false
    @State private var showExportBanner = false
    @State private var exportBannerTask: Task<Void, Never>?

    init(video: VideoModel, environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: EditorDetailViewModel(video: video, environment: environment))
    }

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette

        ZStack {
            palette.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 18)

                preview
                    .padding(.horizontal, 24)
                    .padding(.top, 18)

                VStack(spacing: 20) {
                    toolPicker
                    ScrollView(showsIndicators: false) {
                        toolContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 32)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
            }
            .padding(.bottom, 20)

            if let message = viewModel.errorMessage {
                VStack {
                    Text(message)
                        .font(.footnote.bold())
                        .padding()
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .padding(.top, 40)
                    Spacer()
                }
            }
            if showExportBanner {
                VStack {
                    ExportedToast()
                        .padding(.top, 40)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .tint(.accentColor)
        .onAppear(perform: configurePlayer)
        .onDisappear(perform: teardownPlayer)
        .onChange(of: viewModel.compositionDuration) { duration in
            let maxDuration = max(duration, 0)
            if playhead > maxDuration {
                playhead = maxDuration
            }
        }
        .onReceive(viewModel.$previewPlayerItem.compactMap { $0 }) { item in
            replacePlayerItem(with: item)
        }
        .onChange(of: viewModel.exportSuccess) { success in
            guard success else { return }
            player.pause()
            isPlaying = false
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                showExportBanner = true
            }
            exportBannerTask?.cancel()
            exportBannerTask = Task { [dismiss] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showExportBanner = false
                    }
                    viewModel.acknowledgeExport()
                    dismiss()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item == player.currentItem else { return }
            player.seek(to: .zero)
            playhead = 0
            if isPlaying {
                player.play()
            }
        }
        .onChange(of: viewModel.deleteSuccess) { success in
            if success {
                dismiss()
            }
        }
        .confirmationDialog(
            "Delete Video",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Video", role: .destructive) {
                showDeleteConfirm = false
                viewModel.deleteVideo()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove the video and its edits from MyTube.")
        }
        .onDisappear {
            exportBannerTask?.cancel()
            exportBannerTask = nil
            if viewModel.exportSuccess {
                viewModel.acknowledgeExport()
            }
        }
    }
}

private extension EditorDetailView {
    var header: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        return HStack(spacing: 16) {
            Button {
                player.pause()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(KidCircleIconButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Remix")
                    .font(.title3.bold())
                    .foregroundStyle(palette.accent)
                Text(viewModel.video.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            Spacer()

            if viewModel.isExporting {
                ProgressView()
                    .tint(palette.accent)
            } else {
                Button {
                    viewModel.requestExport()
                } label: {
                    Label("Export", systemImage: "arrow.up.circle.fill")
                        .font(.headline)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    LinearGradient(colors: [palette.accent, palette.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                        )
                        .foregroundStyle(Color.white)
                        .shadow(color: palette.accent.opacity(0.25), radius: 8, y: 5)
                }
                .disabled(!viewModel.isReady || viewModel.isPreviewLoading)
            }

            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(palette.error)
            }
            .disabled(viewModel.isDeleting)
            .buttonStyle(.plain)
        }
    }

    var preview: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black.opacity(0.9))
                    .overlay(
                        VideoPlayer(player: player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .cornerRadius(24)
                    )
                    .shadow(radius: 20)

                if viewModel.isPreviewLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }

                VStack {
                    Spacer()
                    HStack {
                        Label(timeString(for: playhead), systemImage: "clock")
                            .font(.caption.monospacedDigit())
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        if let filter = viewModel.selectedFilterID {
                            Text(filterDisplayName(for: filter))
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.15), in: Capsule())
                        }
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(max(viewModel.sourceAspectRatio, 0.1), contentMode: .fit)

            playbackScrubber
        }
        .padding(20)
        .kidCardBackground()
    }

    var playbackScrubber: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playback")
                .font(.subheadline.bold())
            Slider(
                value: Binding(
                    get: { playhead },
                    set: { newValue in
                        playhead = newValue
                    }
                ),
                in: 0...max(viewModel.compositionDuration, 0.01),
                onEditingChanged: handlePlaybackScrub
            )
            .tint(appEnvironment.activeProfile.theme.kidPalette.accent)
            HStack {
                Text(timeString(for: 0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeString(for: viewModel.compositionDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    var toolPicker: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        return HStack(spacing: 14) {
            ForEach(EditorDetailViewModel.Tool.allCases, id: \.self) { tool in
                let isActive = tool == viewModel.activeTool
                Button {
                    viewModel.setActiveTool(tool)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tool.iconName)
                            .font(.system(size: 18, weight: .medium))
                        Text(tool.displayTitle)
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(isActive ? Color.white : palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(LinearGradient(colors: [palette.accent, palette.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .opacity(isActive ? 1 : 0)
                            )
                    )
                }
                .buttonStyle(.plain)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isActive ? Color.clear : palette.cardStroke, lineWidth: 1)
                )
                .shadow(color: palette.accent.opacity(isActive ? 0.2 : 0.05), radius: isActive ? 8 : 2, y: isActive ? 6 : 2)
            }
        }
    }

    @ViewBuilder
    var toolContent: some View {
        switch viewModel.activeTool {
        case .trim:
            TrimTool(
                start: viewModel.startTime,
                end: viewModel.endTime,
                duration: viewModel.video.duration,
                updateStart: viewModel.updateStartTime,
                updateEnd: viewModel.updateEndTime
            )
        case .effects:
            EffectsTool(viewModel: viewModel)
        case .overlays:
            OverlaysTool(viewModel: viewModel)
        case .audio:
            AudioTool(viewModel: viewModel)
        case .text:
            TextTool(viewModel: viewModel)
        }
    }

    func configurePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { time in
            guard !viewModel.isPreviewLoading, !isScrubbing else { return }
            let seconds = max(time.seconds, 0)
            playhead = min(seconds, viewModel.compositionDuration)
        }
    }

    func teardownPlayer() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
    }

    func replacePlayerItem(with item: AVPlayerItem) {
        isPlaying = false
        player.pause()
        player.replaceCurrentItem(with: item)
        player.seek(to: .zero)
        playhead = 0
    }

    func togglePlayback() {
        guard !viewModel.isPreviewLoading else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func handlePlaybackScrub(_ editing: Bool) {
        isScrubbing = editing
        if editing {
            wasPlayingBeforeScrub = isPlaying
            player.pause()
            isPlaying = false
        } else {
            let time = CMTime(seconds: playhead, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlayingBeforeScrub {
                player.play()
                isPlaying = true
            }
            wasPlayingBeforeScrub = false
        }
    }

    func filterDisplayName(for id: String) -> String {
        viewModel.filters.first(where: { $0.id == id })?.displayName ?? "Custom"
    }

    func timeString(for value: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: value) ?? "0:00"
    }
}

private struct TrimTool: View {
    let start: Double
    let end: Double
    let duration: Double
    let updateStart: (Double) -> Void
    let updateEnd: (Double) -> Void
    @EnvironmentObject private var appEnvironment: AppEnvironment

    private let minimumGap: Double = 2.0

    private var startRange: ClosedRange<Double> {
        0...max(end - minimumGap, 0)
    }

    private var endRange: ClosedRange<Double> {
        min(start + minimumGap, duration)...duration
    }

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(timeString(start))
                        .font(.title3.bold())
                }
                Slider(value: Binding(get: { start }, set: updateStart), in: startRange)
                    .tint(palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("End")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(timeString(end))
                        .font(.title3.bold())
                }
                Slider(value: Binding(get: { end }, set: updateEnd), in: endRange)
                    .tint(palette.accent)
            }
        }
        .padding()
        .kidCardBackground()
    }

    private func timeString(_ value: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: value) ?? "0:00"
    }
}

private struct EffectsTool: View {
    @ObservedObject var viewModel: EditorDetailViewModel
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        VStack(alignment: .leading, spacing: 18) {
            Text("Filters")
                .font(.subheadline.bold())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    FilterChip(
                        title: "Original",
                        isSelected: viewModel.selectedFilterID == nil
                    ) {
                        viewModel.selectedFilterID = nil
                    }

                    ForEach(viewModel.filters) { filter in
                        FilterChip(
                            title: filter.displayName,
                            isSelected: viewModel.selectedFilterID == filter.id
                        ) {
                            viewModel.selectedFilterID = filter.id
                        }
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.2))

            Text("VideoLab Effects")
                .font(.subheadline.bold())

            ForEach(viewModel.effectControls, id: \.id) { control in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(control.displayName, systemImage: control.iconName)
                            .font(.headline)
                        Spacer()
                        Button("Reset") {
                            viewModel.resetEffect(control.id)
                        }
                        .buttonStyle(KidSecondaryButtonStyle())
                    }
                    Slider(
                        value: viewModel.binding(for: control),
                        in: control.normalizedRange
                    )
                    .tint(palette.accent)
                }
            }
        }
        .padding()
        .kidCardBackground()
    }
}

private struct OverlaysTool: View {
    @ObservedObject var viewModel: EditorDetailViewModel
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        VStack(alignment: .leading, spacing: 16) {
            Text("Stickers")
                .font(.subheadline.bold())
                .foregroundStyle(palette.accent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(viewModel.stickers) { sticker in
                        StickerChip(
                            asset: sticker,
                            isSelected: viewModel.selectedSticker?.id == sticker.id
                        ) {
                            viewModel.toggleSticker(sticker)
                        }
                    }
                }
            }

            if viewModel.selectedSticker != nil {
                Button("Remove sticker") {
                    viewModel.clearSticker()
                }
                .buttonStyle(KidSecondaryButtonStyle())
            }
        }
        .padding()
        .kidCardBackground()
    }
}

private struct AudioTool: View {
    @ObservedObject var viewModel: EditorDetailViewModel
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        VStack(alignment: .leading, spacing: 16) {
            Text("Soundtrack")
                .font(.subheadline.bold())
                .foregroundStyle(palette.accent)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(viewModel.musicTracks) { track in
                        MusicTrackRow(
                            track: track,
                            isSelected: viewModel.selectedMusic?.id == track.id
                        ) {
                            viewModel.toggleMusic(track)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)

            if viewModel.selectedMusic != nil {
                Button("Remove music") {
                    viewModel.clearMusic()
                }
                .buttonStyle(KidSecondaryButtonStyle())
            }
        }
        .padding()
        .kidCardBackground()
    }
}

private struct TextTool: View {
    @ObservedObject var viewModel: EditorDetailViewModel
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        VStack(alignment: .leading, spacing: 16) {
            Text("Caption")
                .font(.subheadline.bold())
                .foregroundStyle(palette.accent)
            TextField(
                "Add overlay text",
                text: Binding(
                    get: { viewModel.overlayText },
                    set: { viewModel.overlayText = $0 }
                ),
                axis: .vertical
            )
            .lineLimit(3, reservesSpace: true)
            .textFieldStyle(.roundedBorder)
            .foregroundStyle(.black)
            .padding(12)
            .background(Color.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.cardStroke, lineWidth: 1)
            )

            if !viewModel.overlayText.isEmpty {
                Button("Clear caption") {
                    viewModel.overlayText = ""
                }
                .buttonStyle(KidSecondaryButtonStyle())
            }
        }
        .padding()
        .kidCardBackground()
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        Button(action: action) {
            Text(title)
                .font(.callout.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.6))
                        .overlay(
                            Capsule()
                                .fill(LinearGradient(colors: [palette.accent, palette.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .opacity(isSelected ? 1 : 0)
                        )
                )
                .foregroundStyle(isSelected ? Color.white : palette.accent)
                .shadow(color: palette.accent.opacity(isSelected ? 0.22 : 0.05), radius: isSelected ? 6 : 2, y: isSelected ? 4 : 1)
        }
        .buttonStyle(.plain)
    }
}

private struct StickerChip: View {
    let asset: StickerAsset
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        Button(action: action) {
            VStack(spacing: 10) {
                stickerPreview
                Text(asset.displayName)
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            .frame(width: 96)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(colors: [palette.accent, palette.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .opacity(isSelected ? 1 : 0)
                    )
            )
            .foregroundStyle(isSelected ? Color.white : palette.accent)
            .shadow(color: palette.accent.opacity(isSelected ? 0.25 : 0.05), radius: isSelected ? 8 : 3, y: isSelected ? 6 : 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stickerPreview: some View {
        if let image = ResourceLibrary.stickerImage(named: asset.id) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.3))
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(Color.white.opacity(0.7))
                )
        }
    }
}

private struct MusicTrackRow: View {
    let track: MusicAsset
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.displayName)
                        .font(.body.bold())
                    Text("Loop")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.success)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.65))
            )
            .foregroundStyle(palette.accent)
        }
        .buttonStyle(.plain)
    }
}

private struct ExportedToast: View {
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        Label("Export complete", systemImage: "checkmark.circle.fill")
            .font(.subheadline.bold())
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(Color.white.opacity(0.92))
            )
            .overlay(
                Capsule().stroke(palette.cardStroke, lineWidth: 1)
            )
            .foregroundStyle(palette.accent)
    }
}

private extension EditorDetailViewModel.Tool {
    var displayTitle: String {
        switch self {
        case .trim: return "Trim"
        case .effects: return "Effects"
        case .overlays: return "Stickers"
        case .audio: return "Audio"
        case .text: return "Text"
        }
    }

    var iconName: String {
        switch self {
        case .trim: return "scissors"
        case .effects: return "sparkles"
        case .overlays: return "face.smiling"
        case .audio: return "music.quarternote.3"
        case .text: return "character.cursor.ibeam"
        }
    }
}
