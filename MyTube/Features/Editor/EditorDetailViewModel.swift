//
//  EditorDetailViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SwiftUI
import UIKit

@MainActor
final class EditorDetailViewModel: ObservableObject {
    enum Tool: CaseIterable {
        case trim
        case effects
        case overlays
        case audio
        case text
    }

    struct EffectControl: Identifiable {
        let id: VideoEffectKind
        let displayName: String
        let iconName: String
        let range: ClosedRange<Float>
        let defaultValue: Float

        var normalizedRange: ClosedRange<Double> {
            Double(range.lowerBound)...Double(range.upperBound)
        }
    }

    private static let defaultEffectControls: [EffectControl] = [
        EffectControl(
            id: .zoomBlur,
            displayName: "Zoom Blur",
            iconName: "sparkles",
            range: 0...5,
            defaultValue: 0
        ),
        EffectControl(
            id: .brightness,
            displayName: "Glow",
            iconName: "sun.max.fill",
            range: -0.5...0.5,
            defaultValue: 0
        )
    ]

    @Published private(set) var activeTool: Tool = .trim
    @Published private(set) var startTime: Double
    @Published private(set) var endTime: Double
    @Published private(set) var trimmedDuration: Double
    @Published private(set) var selectedSticker: StickerAsset?
    @Published private(set) var selectedMusic: MusicAsset?
    @Published var overlayText: String = "" {
        didSet {
            guard hasPrepared else { return }
            schedulePreviewRebuild(delay: 250_000_000)
        }
    }
    @Published var selectedFilterID: String? {
        didSet {
            guard hasPrepared else { return }
            schedulePreviewRebuild()
        }
    }
    @Published private(set) var isExporting = false
    @Published private(set) var exportSuccess = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDeleting = false
    @Published private(set) var deleteSuccess = false
    @Published private(set) var filters: [FilterDescriptor] = []
    @Published private(set) var stickers: [StickerAsset] = []
    @Published private(set) var musicTracks: [MusicAsset] = []
    @Published private(set) var effectControls: [EffectControl]
    @Published private(set) var isReady = false
    @Published private(set) var previewPlayerItem: AVPlayerItem?
    @Published private(set) var isPreviewLoading = false
    @Published private(set) var compositionDuration: Double = 0
    @Published private(set) var sourceAspectRatio: CGFloat = 9.0 / 16.0
    @Published private var effectValues: [VideoEffectKind: Float]
    @Published var isScanning = false
    @Published var scanProgress: String?

    let video: VideoModel

    private let environment: AppEnvironment
    private let sourceURL: URL
    private var hasPrepared = false
    private var previewRefreshTask: Task<Void, Never>?
    private let minimumClipLength: Double = 2.0

    init(video: VideoModel, environment: AppEnvironment) {
        self.video = video
        self.environment = environment
        self.sourceURL = environment.videoLibrary.videoFileURL(for: video)
        self.startTime = 0
        self.endTime = video.duration
        self.trimmedDuration = video.duration
        self.selectedFilterID = nil
        self.effectControls = Self.defaultEffectControls
        self.effectValues = Dictionary(
            uniqueKeysWithValues: Self.defaultEffectControls.map { ($0.id, $0.defaultValue) }
        )

        if !FileManager.default.fileExists(atPath: sourceURL.path) {
            self.errorMessage = "Original video file is missing."
        }

        Task { await prepare() }
    }

    func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        isReady = false
        await Task.yield()

        filters = FilterPipeline.presets() + FilterPipeline.lutPresets()
        stickers = ResourceLibrary.stickers()
        musicTracks = ResourceLibrary.musicTracks()
        updateSourceAspectRatio()
        trimmedDuration = endTime - startTime
        compositionDuration = trimmedDuration
        isReady = true
        await rebuildPreview()
    }

    func setActiveTool(_ tool: Tool) {
        guard activeTool != tool else { return }
        activeTool = tool
    }

    func updateStartTime(_ value: Double) {
        let clamped = max(0, min(value, endTime - minimumClipLength))
        guard abs(clamped - startTime) > .ulpOfOne else { return }
        startTime = clamped
        trimmedDuration = endTime - startTime
        compositionDuration = trimmedDuration
        schedulePreviewRebuild()
    }

    func updateEndTime(_ value: Double) {
        let clamped = min(max(value, startTime + minimumClipLength), video.duration)
        guard abs(clamped - endTime) > .ulpOfOne else { return }
        endTime = clamped
        trimmedDuration = endTime - startTime
        compositionDuration = trimmedDuration
        schedulePreviewRebuild()
    }

    func toggleSticker(_ sticker: StickerAsset) {
        if selectedSticker?.id == sticker.id {
            selectedSticker = nil
        } else {
            selectedSticker = sticker
        }
        schedulePreviewRebuild()
    }

    func clearSticker() {
        guard selectedSticker != nil else { return }
        selectedSticker = nil
        schedulePreviewRebuild()
    }

    func toggleMusic(_ track: MusicAsset) {
        if selectedMusic?.id == track.id {
            selectedMusic = nil
        } else {
            selectedMusic = track
        }
        schedulePreviewRebuild()
    }

    func clearMusic() {
        guard selectedMusic != nil else { return }
        selectedMusic = nil
        schedulePreviewRebuild()
    }

    func effectValue(for kind: VideoEffectKind) -> Float {
        effectValues[kind] ?? effectControls.first(where: { $0.id == kind })?.defaultValue ?? 0
    }

    func setEffect(_ kind: VideoEffectKind, value: Float) {
        guard let control = effectControls.first(where: { $0.id == kind }) else { return }
        let clamped = min(max(value, control.range.lowerBound), control.range.upperBound)
        guard effectValues[kind] != clamped else { return }
        effectValues[kind] = clamped
        schedulePreviewRebuild()
    }

    func resetEffect(_ kind: VideoEffectKind) {
        guard let control = effectControls.first(where: { $0.id == kind }) else { return }
        effectValues[kind] = control.defaultValue
        schedulePreviewRebuild()
    }

    func binding(for control: EffectControl) -> Binding<Double> {
        Binding(
            get: { Double(self.effectValue(for: control.id)) },
            set: { [weak self] newValue in
                self?.setEffect(control.id, value: Float(newValue))
            }
        )
    }

    func resetEdit() {
        updateStartTime(0)
        updateEndTime(video.duration)
        selectedFilterID = nil
        overlayText = ""
        selectedSticker = nil
        selectedMusic = nil
        effectControls.forEach { control in
            effectValues[control.id] = control.defaultValue
        }
        schedulePreviewRebuild(delay: 0)
    }

    func requestExport() {
        guard !isExporting else { return }
        exportEdit()
    }

    func exportEdit() {
        guard !isExporting else { return }
        guard trimmedDuration >= minimumClipLength else {
            errorMessage = "Clip must be at least \(Int(minimumClipLength)) seconds."
            return
        }

        isExporting = true
        errorMessage = nil

        Task {
            isScanning = true
            scanProgress = "Preparing scan…"
            defer {
                isExporting = false
                isScanning = false
                scanProgress = nil
            }
            do {
                let composition = makeComposition()
                let profileId = environment.activeProfile.id
                let screenScale = await MainActor.run { UIScreen.main.scale }
                let exportedURL = try await environment.editRenderer.exportEdit(
                    composition,
                    profileId: profileId,
                    screenScale: screenScale
                )
                let thumbnailURL = try await environment.thumbnailer.generateThumbnail(
                    for: exportedURL,
                    profileId: profileId
                )

                let request = VideoCreationRequest(
                    profileId: profileId,
                    sourceURL: exportedURL,
                    thumbnailURL: thumbnailURL,
                    title: video.title + " Remix",
                    duration: trimmedDuration,
                    tags: video.tags,
                    cvLabels: video.cvLabels,
                    faceCount: video.faceCount,
                    loudness: video.loudness
                )

                _ = try await environment.videoLibrary.createVideo(request: request) { [weak self] progress in
                    Task { @MainActor in
                        self?.scanProgress = progress
                    }
                }
                try? FileManager.default.removeItem(at: exportedURL)
                try? FileManager.default.removeItem(at: thumbnailURL)
                exportSuccess = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func acknowledgeExport() {
        exportSuccess = false
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

    func rebuildPreviewImmediately() {
        previewRefreshTask?.cancel()
        previewRefreshTask = Task {
            await rebuildPreview()
        }
    }

    func makeComposition() -> EditComposition {
        let clip = ClipSegment(
            sourceURL: sourceURL,
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            end: CMTime(seconds: endTime, preferredTimescale: 600)
        )
        let clipDuration = CMTimeSubtract(clip.end, clip.start)

        var overlays: [OverlayItem] = []
        if let sticker = selectedSticker {
            let stickerFrame = CGRect(x: 80, y: 80, width: 300, height: 300)
            overlays.append(
                OverlayItem(
                    content: .sticker(name: sticker.id),
                    frame: stickerFrame,
                    start: .zero,
                    end: clipDuration
                )
            )
        }

        if !overlayText.isEmpty {
            overlays.append(
                OverlayItem(
                    content: .text(overlayText, fontName: "Avenir-Heavy", color: .white),
                    frame: CGRect(x: 120, y: 540, width: 1040, height: 140),
                    start: .zero,
                    end: clipDuration
                )
            )
        }

        var tracks: [AudioTrack] = []
        if let music = selectedMusic {
            tracks.append(
                AudioTrack(resourceName: music.id, startOffset: .zero, volume: 0.8)
            )
        }

        return EditComposition(
            clip: clip,
            overlays: overlays,
            audioTracks: tracks,
            filterName: selectedFilterID,
            videoEffects: buildVideoEffects()
        )
    }

    private func buildVideoEffects() -> [VideoEffect] {
        effectControls.compactMap { control in
            let value = effectValues[control.id] ?? control.defaultValue
            let epsilon: Float = 0.0001
            guard abs(value - control.defaultValue) > epsilon else { return nil }
            switch control.id {
            case .zoomBlur:
                return VideoEffect(
                    kind: .zoomBlur,
                    intensity: value,
                    center: CGPoint(x: 0.5, y: 0.5)
                )
            case .brightness:
                return VideoEffect(
                    kind: .brightness,
                    intensity: value
                )
            }
        }
    }

    private func schedulePreviewRebuild(delay: UInt64 = 120_000_000) {
        guard hasPrepared else { return }
        previewRefreshTask?.cancel()
        previewRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.rebuildPreview()
        }
    }

    private func rebuildPreview() async {
        guard hasPrepared else { return }
        isPreviewLoading = true
        let composition = makeComposition()
        do {
            let screenScale = await MainActor.run { UIScreen.main.scale }
            let item = try await environment.editRenderer.makePreviewPlayerItem(for: composition, screenScale: screenScale)
            previewPlayerItem = item
            compositionDuration = composition.clipDuration.seconds
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreviewLoading = false
    }

    private func updateSourceAspectRatio() {
        let asset = AVURLAsset(url: sourceURL)
        if let track = asset.tracks(withMediaType: .video).first {
            let transformed = track.naturalSize.applying(track.preferredTransform)
            let width = max(abs(transformed.width), 1)
            let height = max(abs(transformed.height), 1)
            sourceAspectRatio = CGFloat(width / height)
        }
    }
}

private extension EditComposition {
    var clipDuration: CMTime {
        CMTimeSubtract(clip.end, clip.start)
    }
}
