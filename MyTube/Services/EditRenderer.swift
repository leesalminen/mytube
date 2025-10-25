//
//  EditRenderer.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVFoundation
import CoreImage
import UIKit
import QuartzCore
import SwiftUI

enum EditRendererError: Error {
    case exportFailed
    case trackInsertionFailed
    case audioResourceMissing
}

final class EditRenderer {
    private let storagePaths: StoragePaths
    private let queue = DispatchQueue(label: "com.mytube.editrenderer")

    init(storagePaths: StoragePaths) {
        self.storagePaths = storagePaths
    }

    func exportEdit(
        _ composition: EditComposition,
        profileId: UUID
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
                    let exportSession = try self.makeExportSession(for: composition)
                    exportSession.outputURL = destinationURL
                    exportSession.outputFileType = .mp4
                    exportSession.exportAsynchronously {
                        switch exportSession.status {
                        case .completed:
                            do {
                                #if os(iOS)
                                try? FileManager.default.setAttributes(
                                    [FileAttributeKey.protectionKey: FileProtectionType.complete],
                                    ofItemAtPath: destinationURL.path
                                )
                                #endif
                                continuation.resume(returning: destinationURL)
                            } catch {
                                continuation.resume(throwing: error)
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

    private func makeExportSession(for edit: EditComposition) throws -> AVAssetExportSession {
        let asset = AVAsset(url: edit.clip.sourceURL)
        let composition = try buildMutableComposition(asset: asset, segment: edit.clip, audioTracks: edit.audioTracks)
        let videoComposition = try buildVideoComposition(
            composition: composition,
            overlays: edit.overlays,
            filterName: edit.filterName,
            duration: edit.clip.end - edit.clip.start
        )

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw EditRendererError.exportFailed
        }
        exportSession.videoComposition = videoComposition
        return exportSession
    }

    private func buildMutableComposition(
        asset: AVAsset,
        segment: ClipSegment,
        audioTracks: [AudioTrack]
    ) throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw EditRendererError.trackInsertionFailed
        }

        let timeRange = CMTimeRange(start: segment.start, end: segment.end)

        guard
            let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else { throw EditRendererError.trackInsertionFailed }

        try compositionVideoTrack.insertTimeRange(
            timeRange,
            of: videoTrack,
            at: .zero
        )
        compositionVideoTrack.preferredTransform = videoTrack.preferredTransform

        if let originalAudioTrack = asset.tracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compositionAudioTrack.insertTimeRange(timeRange, of: originalAudioTrack, at: .zero)
        }

        let clipDuration = segment.end - segment.start
        guard CMTimeCompare(clipDuration, .zero) > 0 else { return composition }

        for audio in audioTracks {
            guard let url = ResourceLibrary.musicURL(for: audio.resourceName) else {
                throw EditRendererError.audioResourceMissing
            }
            let musicAsset = AVAsset(url: url)
            guard let track = musicAsset.tracks(withMediaType: .audio).first,
                  let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let musicDuration = track.timeRange.duration
            guard CMTimeCompare(musicDuration, .zero) > 0 else { continue }

            let startOffset: CMTime = CMTimeCompare(audio.startOffset, .zero) >= 0 ? audio.startOffset : .zero
            if CMTimeCompare(clipDuration, startOffset) <= 0 { continue }

            compositionTrack.preferredVolume = audio.volume

            var insertTime = startOffset
            var remaining = CMTimeSubtract(clipDuration, insertTime)

            while CMTimeCompare(remaining, .zero) > 0 {
                let chunkDuration = CMTimeCompare(remaining, musicDuration) <= 0 ? remaining : musicDuration
                if CMTimeCompare(chunkDuration, .zero) <= 0 { break }
                let timeRange = CMTimeRange(start: .zero, duration: chunkDuration)
                try compositionTrack.insertTimeRange(timeRange, of: track, at: insertTime)
                insertTime = CMTimeAdd(insertTime, chunkDuration)
                remaining = CMTimeSubtract(clipDuration, insertTime)
            }
        }

        return composition
    }

    private func buildVideoComposition(
        composition: AVMutableComposition,
        overlays: [OverlayItem],
        filterName: String?,
        duration: CMTime
    ) throws -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            var image = request.sourceImage
            if let filterName, let filter = CIFilter(name: filterName) {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage ?? image
            }
            request.finish(with: image, context: nil)
        }
        let naturalSize = composition.tracks(withMediaType: .video).first?.naturalSize ?? CGSize(width: 1280, height: 720)
        videoComposition.renderSize = naturalSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        if !overlays.isEmpty {
            let parent = CALayer()
            let videoLayer = CALayer()
            let overlayLayer = CALayer()

            parent.frame = CGRect(origin: .zero, size: naturalSize)
            videoLayer.frame = CGRect(origin: .zero, size: naturalSize)
            overlayLayer.frame = CGRect(origin: .zero, size: naturalSize)

            for item in overlays {
                overlayLayer.addSublayer(makeOverlayLayer(item: item, renderSize: naturalSize))
            }

            parent.addSublayer(videoLayer)
            parent.addSublayer(overlayLayer)

            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: parent
            )
        }

        return videoComposition
    }

    private func makeOverlayLayer(item: OverlayItem, renderSize: CGSize) -> CALayer {
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
            textLayer.contentsScale = UIScreen.main.scale
            layer.addSublayer(textLayer)
        }

        return layer
    }
}
