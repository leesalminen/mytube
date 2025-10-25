//
//  EditorDetailView.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVKit
import SwiftUI
import UIKit

struct EditorDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: EditorDetailViewModel
    @State private var player: AVPlayer
    @State private var showDeleteConfirm = false

    init(video: VideoModel, environment: AppEnvironment) {
        let model = EditorDetailViewModel(video: video, environment: environment)
        _viewModel = StateObject(wrappedValue: model)
        _player = State(initialValue: AVPlayer(playerItem: model.playerItem))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    EditorPreviewSection(viewModel: viewModel, player: $player)
                    EditorFilterSection(viewModel: viewModel)
                    if !viewModel.stickers.isEmpty {
                        EditorStickerSection(viewModel: viewModel)
                    }
                    EditorOverlaySection(overlayText: $viewModel.overlayText)
                    if !viewModel.musicTracks.isEmpty {
                        EditorMusicSection(viewModel: viewModel)
                    }
                    if let message = viewModel.errorMessage {
                        EditorErrorSection(message: message)
                    }
                }
                .disabled(!viewModel.isReady || viewModel.isDeleting)

                if !viewModel.isReady {
                    ZStack {
                        Color.black.opacity(0.1)
                            .ignoresSafeArea()
                        LoadingOverlay(message: "Loading editor…")
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle("Edit")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") { viewModel.resetEdit() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if viewModel.isDeleting {
                        ProgressView()
                    } else {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isExporting {
                        ProgressView()
                    } else {
                        Button("Export") { viewModel.exportEdit() }
                            .disabled(viewModel.isDeleting)
                    }
                }
            }
            .onChange(of: viewModel.exportSuccess) { success in
                if success {
                    dismiss()
                }
            }
            .onChange(of: viewModel.deleteSuccess) { deleted in
                if deleted {
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
        }
    }

}

private struct EditorPreviewSection: View {
    @ObservedObject var viewModel: EditorDetailViewModel
    @Binding var player: AVPlayer

    var body: some View {
        Section(header: Text("Preview")) {
            VideoPlayer(player: player)
                .frame(height: 240)
                .cornerRadius(12)
                .onAppear { player.play() }
                .onDisappear { player.pause() }

            TimeSlider(
                title: "Start",
                value: $viewModel.startTime,
                range: 0...max(0, viewModel.endTime - 1)
            ) {
                if $0 >= viewModel.endTime { viewModel.startTime = viewModel.endTime - 1 }
            }

            TimeSlider(
                title: "End",
                value: $viewModel.endTime,
                range: max(viewModel.startTime + 1, 1)...viewModel.video.duration
            ) {
                if $0 <= viewModel.startTime { viewModel.endTime = viewModel.startTime + 1 }
            }
        }
    }
}

private struct EditorFilterSection: View {
    @ObservedObject var viewModel: EditorDetailViewModel

    var body: some View {
        Section(header: Text("Filters")) {
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
                .padding(.vertical, 8)
            }
        }
    }
}

private struct EditorStickerSection: View {
    @ObservedObject var viewModel: EditorDetailViewModel

    var body: some View {
        Section(header: Text("Stickers")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(viewModel.stickers) { sticker in
                        StickerChip(
                            asset: sticker,
                            isSelected: viewModel.selectedSticker?.id == sticker.id
                        ) {
                            viewModel.selectedSticker = viewModel.selectedSticker?.id == sticker.id ? nil : sticker
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

private struct EditorOverlaySection: View {
    @Binding var overlayText: String

    var body: some View {
        Section(header: Text("Overlay Text")) {
            TextField("Add caption", text: $overlayText)
        }
    }
}

private struct EditorMusicSection: View {
    @ObservedObject var viewModel: EditorDetailViewModel

    var body: some View {
        Section(header: Text("Background Music")) {
            ForEach(viewModel.musicTracks) { track in
                MusicTrackRow(
                    track: track,
                    isSelected: viewModel.selectedMusic?.id == track.id
                ) {
                    if viewModel.selectedMusic?.id == track.id {
                        viewModel.selectedMusic = nil
                    } else {
                        viewModel.selectedMusic = track
                    }
                }
            }

            ClearMusicButton {
                viewModel.selectedMusic = nil
            }
        }
    }
}

private struct EditorErrorSection: View {
    let message: String

    var body: some View {
        Section {
            Text(message)
                .foregroundStyle(.red)
        }
    }
}

private struct MusicTrackRow: View {
    let track: MusicAsset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(track.displayName)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ClearMusicButton: View {
    let action: () -> Void

    var body: some View {
        Button("Clear music", action: action)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
    }
}

private struct LoadingOverlay: View {
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.accentColor)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 28)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}

private struct TimeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onChange: (Double) -> Void

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
                .onChange(of: value, perform: onChange)
            Text(timeString(value))
                .font(.caption)
                .frame(width: 56)
        }
    }

    private func timeString(_ value: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: value) ?? "0:00"
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct StickerChip: View {
    let asset: StickerAsset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                stickerPreview
                Text(asset.displayName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: 88)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .padding(10)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                .padding(10)
        }
    }
}
