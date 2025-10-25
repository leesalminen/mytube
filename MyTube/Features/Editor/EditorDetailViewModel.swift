//
//  EditorDetailViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVFoundation
import CoreMedia
import Foundation
import SwiftUI

@MainActor
final class EditorDetailViewModel: ObservableObject {
    @Published var startTime: Double
    @Published var endTime: Double
    @Published var selectedFilterID: String?
    @Published var overlayText: String = ""
    @Published var isExporting = false
    @Published var exportSuccess = false
    @Published var errorMessage: String?
    @Published var selectedSticker: StickerAsset?
    @Published var selectedMusic: MusicAsset?
    @Published var isDeleting = false
    @Published var deleteSuccess = false
    @Published private(set) var filters: [FilterDescriptor] = []
    @Published private(set) var stickers: [StickerAsset] = []
    @Published private(set) var musicTracks: [MusicAsset] = []
    @Published private(set) var isReady = false

    let video: VideoModel
    let playerItem: AVPlayerItem

    private let environment: AppEnvironment
    private var hasPrepared = false

    init(video: VideoModel, environment: AppEnvironment) {
        self.video = video
        self.environment = environment
        self.startTime = 0
        self.endTime = video.duration
        let url = environment.videoLibrary.videoFileURL(for: video)
        self.playerItem = AVPlayerItem(url: url)
        if !FileManager.default.fileExists(atPath: url.path) {
            self.errorMessage = "Original video file is missing."
        }
        Task { await prepare() }
    }

    func resetEdit() {
        startTime = 0
        endTime = video.duration
        selectedFilterID = nil
        overlayText = ""
        selectedSticker = nil
        selectedMusic = nil
    }

    func exportEdit() {
        guard endTime - startTime >= 2 else {
            errorMessage = "Clip must be at least 2 seconds."
            return
        }

        isExporting = true
        errorMessage = nil

        Task {
            do {
                let clip = ClipSegment(
                    sourceURL: environment.videoLibrary.videoFileURL(for: video),
                    start: CMTime(seconds: startTime, preferredTimescale: 600),
                    end: CMTime(seconds: endTime, preferredTimescale: 600)
                )

                var overlays: [OverlayItem] = []
                if let sticker = selectedSticker {
                    let stickerFrame = CGRect(x: 80, y: 80, width: 300, height: 300)
                    overlays.append(
                        OverlayItem(
                            content: .sticker(name: sticker.id),
                            frame: stickerFrame,
                            start: .zero,
                            end: clip.end - clip.start
                        )
                    )
                }
                if !overlayText.isEmpty {
                    overlays.append(
                        OverlayItem(
                            content: .text(overlayText, fontName: "Avenir-Heavy", color: .white),
                            frame: CGRect(x: 120, y: 540, width: 1040, height: 140),
                            start: .zero,
                            end: clip.end - clip.start
                        )
                    )
                }

                var tracks: [AudioTrack] = []
                if let music = selectedMusic {
                    tracks.append(
                        AudioTrack(resourceName: music.id, startOffset: .zero, volume: 0.8)
                    )
                }

                let composition = EditComposition(
                    clip: clip,
                    overlays: overlays,
                    audioTracks: tracks,
                    filterName: selectedFilterID
                )

                let profileId = environment.activeProfile.id
                let exportedURL = try await environment.editRenderer.exportEdit(composition, profileId: profileId)
                let thumbnailURL = try await environment.thumbnailer.generateThumbnail(for: exportedURL, profileId: profileId)

                let request = VideoCreationRequest(
                    profileId: profileId,
                    sourceURL: exportedURL,
                    thumbnailURL: thumbnailURL,
                    title: video.title + " Remix",
                    duration: endTime - startTime,
                    tags: video.tags,
                    cvLabels: video.cvLabels,
                    faceCount: video.faceCount,
                    loudness: video.loudness
                )

                _ = try await environment.videoLibrary.createVideo(request: request)
                try? FileManager.default.removeItem(at: exportedURL)
                try? FileManager.default.removeItem(at: thumbnailURL)
                exportSuccess = true
            } catch {
                errorMessage = error.localizedDescription
            }

            isExporting = false
        }
    }

    func deleteVideo() {
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil

        Task {
            do {
                try await environment.videoLibrary.deleteVideo(videoId: video.id)
                deleteSuccess = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeleting = false
        }
    }

    func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        isReady = false
        await Task.yield()

        let filters = FilterPipeline.presets() + FilterPipeline.lutPresets()
        let stickers = ResourceLibrary.stickers()
        let tracks = ResourceLibrary.musicTracks()

        self.filters = filters
        self.stickers = stickers
        self.musicTracks = tracks
        isReady = true
    }
}
