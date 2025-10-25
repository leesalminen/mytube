//
//  Thumbnailer.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVFoundation
import UIKit

enum ThumbnailError: Error {
    case generationFailed
    case fileWriteFailed
}

final class Thumbnailer {
    private let storagePaths: StoragePaths
    private let queue: DispatchQueue

    init(storagePaths: StoragePaths, queue: DispatchQueue = DispatchQueue(label: "com.mytube.thumbnailer")) {
        self.storagePaths = storagePaths
        self.queue = queue
    }

    func generateThumbnail(for videoURL: URL, profileId: UUID, at time: CMTime = CMTime(seconds: 0.5, preferredTimescale: 600)) async throws -> URL {
        try storagePaths.ensureProfileContainers(profileId: profileId)
        let thumbURL = storagePaths.url(
            for: .thumbs,
            profileId: profileId,
            fileName: UUID().uuidString + ".jpg"
        )

        let cgImage = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let image = try self.copyImage(for: videoURL, at: time)
                    continuation.resume(returning: image)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw ThumbnailError.generationFailed
        }
        do {
            try data.write(to: thumbURL, options: .atomic)
            #if os(iOS)
            try? FileManager.default.setAttributes(
                [FileAttributeKey.protectionKey: FileProtectionType.complete],
                ofItemAtPath: thumbURL.path
            )
            #endif
        } catch {
            throw ThumbnailError.fileWriteFailed
        }

        return thumbURL
    }

    private func copyImage(for videoURL: URL, at time: CMTime) throws -> CGImage {
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        return try generator.copyCGImage(at: time, actualTime: nil)
    }
}
