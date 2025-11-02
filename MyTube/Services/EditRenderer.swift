//
//  EditRenderer.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVFoundation
import CoreImage
import QuartzCore
import SwiftUI
import UIKit
import VideoLab

enum EditRendererError: Error {
    case exportFailed
    case trackInsertionFailed
    case audioResourceMissing
    case missingVideoTrack
    case invalidClipRange
}

final class EditRenderer {
    private let storagePaths: StoragePaths
    private let queue = DispatchQueue(label: "com.mytube.editrenderer")
    private let filterContext = CIContext(options: nil)

    init(storagePaths: StoragePaths) {
        self.storagePaths = storagePaths
    }

    func exportEdit(
        _ composition: EditComposition,
        profileId: UUID,
        screenScale: CGFloat
    ) async throws -> URL {
        try storagePaths.ensureProfileContainers(profileId: profileId)
        let destinationURL = storagePaths.url(
            for: .edits,
            profileId: profileId,
            fileName: UUID().uuidString + ".mp4"
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let context = try self.makeVideoLabContext(for: composition, screenScale: screenScale)
                    let filterName = composition.filterName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let needsFilter = (filterName?.isEmpty == false)

                    let exportURL: URL = needsFilter ? self.makeTemporaryURL(extension: "mp4") : destinationURL

                    guard let exportSession = context.videoLab.makeExportSession(
                        presetName: AVAssetExportPresetHighestQuality,
                        outputURL: exportURL
                    ) else {
                        throw EditRendererError.exportFailed
                    }

                    exportSession.exportAsynchronously {
                        switch exportSession.status {
                        case .completed:
                            let finalize = {
                                #if os(iOS)
                                try? FileManager.default.setAttributes(
                                    [FileAttributeKey.protectionKey: FileProtectionType.complete],
                                    ofItemAtPath: destinationURL.path
                                )
                                #endif
                            }

                            guard needsFilter, let name = filterName, !name.isEmpty else {
                                finalize()
                                continuation.resume(returning: destinationURL)
                                return
                            }

                            Task.detached(priority: .userInitiated) {
                                do {
                                    try await self.applyFilter(
                                        filterName: name,
                                        inputURL: exportURL,
                                        outputURL: destinationURL
                                    )
                                    finalize()
                                    try? FileManager.default.removeItem(at: exportURL)
                                    continuation.resume(returning: destinationURL)
                                } catch {
                                    try? FileManager.default.removeItem(at: exportURL)
                                    continuation.resume(throwing: error)
                                }
                            }
                        case .failed, .cancelled:
                            continuation.resume(throwing: exportSession.error ?? EditRendererError.exportFailed)
                        default:
                            break
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func makePreviewPlayerItem(for composition: EditComposition, screenScale: CGFloat) async throws -> AVPlayerItem {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let context = try self.makeVideoLabContext(for: composition, screenScale: screenScale)
                    let item = context.videoLab.makePlayerItem()
                    continuation.resume(returning: item)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func makeVideoLabContext(for edit: EditComposition, screenScale: CGFloat) throws -> VideoLabContext {
        let asset = AVURLAsset(url: edit.clip.sourceURL)
        let clipRange = CMTimeRange(start: edit.clip.start, end: edit.clip.end)
        guard clipRange.duration > .zero else {
            throw EditRendererError.invalidClipRange
        }
        let renderSize = try naturalRenderSize(for: asset)
        let frameDuration = makeFrameDuration(for: asset)

        let composition = RenderComposition()
        composition.renderSize = renderSize
        composition.frameDuration = frameDuration

        let videoSource = AVAssetSource(asset: asset)
        videoSource.selectedTimeRange = clipRange
        let baseLayer = RenderLayer(
            timeRange: CMTimeRange(start: .zero, duration: clipRange.duration),
            source: videoSource
        )
        if !edit.videoEffects.isEmpty {
            baseLayer.operations = edit.videoEffects.compactMap { effect in
                switch effect.kind {
                case .zoomBlur:
                    let operation = ZoomBlur()
                    operation.blurSize = max(0.0, effect.intensity)
                    if let center = effect.center {
                        operation.blurCenter = Position2D(Float(center.x), Float(center.y))
                    }
                    return operation
                case .brightness:
                    let operation = BrightnessAdjustment()
                    operation.brightness = effect.intensity
                    return operation
                }
            }
        }
        composition.layers = [baseLayer]

        if !edit.overlays.isEmpty {
            var overlayRoot: CALayer?
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                overlayRoot = self.makeOverlayContainer(overlays: edit.overlays, renderSize: renderSize, screenScale: screenScale)
                semaphore.signal()
            }
            semaphore.wait()
            composition.animationLayer = overlayRoot
        }

        if !edit.audioTracks.isEmpty {
            try appendAudioLayers(
                to: composition,
                clipDuration: clipRange.duration,
                tracks: edit.audioTracks
            )
        }

        return VideoLabContext(
            videoLab: VideoLab(renderComposition: composition)
        )
    }

    private func appendAudioLayers(
        to composition: RenderComposition,
        clipDuration: CMTime,
        tracks: [AudioTrack]
    ) throws {
        for track in tracks {
            guard let url = ResourceLibrary.musicURL(for: track.resourceName) else {
                throw EditRendererError.audioResourceMissing
            }
            let audioAsset = AVURLAsset(url: url)
            let audioDuration = audioAsset.duration
            guard audioDuration > .zero else { continue }

            let startOffset = track.startOffset >= .zero ? track.startOffset : .zero
            guard startOffset < clipDuration else { continue }

            var remaining = CMTimeSubtract(clipDuration, startOffset)
            var currentStart = startOffset

            while remaining > .zero {
                let segmentDuration = CMTimeCompare(remaining, audioDuration) >= 0 ? audioDuration : remaining
                let source = AVAssetSource(asset: audioAsset)
                source.selectedTimeRange = CMTimeRange(start: .zero, duration: segmentDuration)

                let layer = RenderLayer(
                    timeRange: CMTimeRange(start: currentStart, duration: segmentDuration),
                    source: source
                )
                layer.audioConfiguration = AudioConfiguration(
                    pitchAlgorithm: .timeDomain,
                    volumeRamps: [
                        VolumeRamp(
                            startVolume: track.volume,
                            endVolume: track.volume,
                            timeRange: CMTimeRange(start: .zero, duration: segmentDuration)
                        )
                    ]
                )
                layer.layerLevel = 100
                composition.layers.append(layer)

                currentStart = currentStart + segmentDuration
                remaining = remaining - segmentDuration
            }
        }
    }

    private func makeOverlayContainer(overlays: [OverlayItem], renderSize: CGSize, screenScale: CGFloat) -> CALayer? {
        guard !overlays.isEmpty else { return nil }
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.masksToBounds = false
        overlays.forEach { item in
            parent.addSublayer(makeOverlayLayer(item: item, renderSize: renderSize, screenScale: screenScale))
        }
        return parent
    }

    private func makeOverlayLayer(item: OverlayItem, renderSize: CGSize, screenScale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.frame = item.frame
        layer.opacity = 1.0

        switch item.content {
        case .sticker(let name):
            if let image = ResourceLibrary.stickerImage(named: name)?.cgImage {
                layer.contents = image
                layer.contentsGravity = .resizeAspect
            }
        case .text(let text, let fontName, let color):
            let textLayer = CATextLayer()
            textLayer.string = text
            textLayer.font = UIFont(name: fontName, size: 48) ?? UIFont.systemFont(ofSize: 48, weight: .bold)
            textLayer.fontSize = 48
            textLayer.foregroundColor = UIColor(color).cgColor
            textLayer.alignmentMode = .center
            textLayer.frame = layer.bounds
            textLayer.contentsScale = screenScale
            layer.addSublayer(textLayer)
        }

        return layer
    }

    private func applyFilter(filterName: String, inputURL: URL, outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let asset = AVAsset(url: inputURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw EditRendererError.exportFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = AVVideoComposition(asset: asset) { [filterContext] request in
            let source = request.sourceImage.clampedToExtent()
            guard let filtered = FilterPipeline.apply(filterName: filterName, to: source) else {
                request.finish(with: request.sourceImage, context: filterContext)
                return
            }
            let output = filtered.cropped(to: request.sourceImage.extent)
            request.finish(with: output, context: filterContext)
        }

        try await export(session: exportSession)
    }

    private func export(session: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: session.error ?? EditRendererError.exportFailed)
                default:
                    break
                }
            }
        }
    }

    private func naturalRenderSize(for asset: AVAsset) throws -> CGSize {
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw EditRendererError.missingVideoTrack
        }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private func makeFrameDuration(for asset: AVAsset) -> CMTime {
        guard let track = asset.tracks(withMediaType: .video).first else {
            return CMTime(value: 1, timescale: 30)
        }
        let nominal = track.nominalFrameRate
        guard nominal > 0 else {
            return CMTime(value: 1, timescale: 30)
        }
        return CMTime(value: 1, timescale: Int32(nominal.rounded()))
    }

    private func makeTemporaryURL(extension fileExtension: String) -> URL {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.mytube.edit-renderer", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        return tempBase.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    }
}

private struct VideoLabContext {
    let videoLab: VideoLab
}
