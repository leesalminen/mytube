//
//  VideoLibrary.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import CoreData
import Foundation

enum VideoLibraryError: Error {
    case profileMissing
    case entityMissing
    case fileOperationFailed(Error)
    case invalidFeedbackAction
}

final class VideoLibrary {
    private let persistence: PersistenceController
    private let storagePaths: StoragePaths
    private let fileManager: FileManager
    private let jsonEncoder = JSONEncoder()

    init(
        persistence: PersistenceController,
        storagePaths: StoragePaths,
        fileManager: FileManager = .default
    ) {
        self.persistence = persistence
        self.storagePaths = storagePaths
        self.fileManager = fileManager
    }

    func createVideo(request: VideoCreationRequest) async throws -> VideoModel {
        let videoId = UUID()
        try storagePaths.ensureProfileContainers(profileId: request.profileId)

        let videoFileURL = storagePaths.url(
            for: .media,
            profileId: request.profileId,
            fileName: videoId.uuidString + request.sourceURL.pathExtensionWithDot
        )
        let thumbFileURL = storagePaths.url(
            for: .thumbs,
            profileId: request.profileId,
            fileName: videoId.uuidString + request.thumbnailURL.pathExtensionWithDot
        )

        try copyItemIfNeeded(from: request.sourceURL, to: videoFileURL)
        try copyItemIfNeeded(from: request.thumbnailURL, to: thumbFileURL)

        return try await performBackground { [self] context in
            let entity = VideoEntity(context: context)
            entity.id = videoId
            entity.profileId = request.profileId
            entity.filePath = self.relativePath(for: videoFileURL)
            entity.thumbPath = self.relativePath(for: thumbFileURL)
            entity.title = request.title
            entity.duration = request.duration
            entity.createdAt = Date()
            entity.lastPlayedAt = nil
            entity.playCount = 0
            entity.completionRate = 0
            entity.replayRate = 0
            entity.liked = false
            entity.hidden = false
            entity.tagsJSON = self.encodeJSON(request.tags)
            entity.cvLabelsJSON = self.encodeJSON(request.cvLabels)
            entity.faceCount = Int16(request.faceCount)
            entity.loudness = request.loudness

            try context.save()

            guard let model = VideoModel(entity: entity) else {
                throw VideoLibraryError.entityMissing
            }
            return model
        }
    }

    func fetchVideos(profileId: UUID, includeHidden: Bool = false) throws -> [VideoModel] {
        let request = VideoEntity.fetchRequest()
        request.predicate = includeHidden
            ? NSPredicate(format: "profileId == %@", profileId as CVarArg)
            : NSPredicate(format: "profileId == %@ AND hidden == NO", profileId as CVarArg)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \VideoEntity.createdAt, ascending: false)
        ]

        let entities = try persistence.viewContext.fetch(request)
        return entities.compactMap(VideoModel.init(entity:))
    }

    func updateMetrics(_ update: PlaybackMetricUpdate) async throws -> VideoModel {
        try await performBackground { [self] context in
            guard let entity = try fetchVideo(in: context, id: update.videoId) else {
                throw VideoLibraryError.entityMissing
            }

            if update.playCountDelta != 0 {
                entity.playCount = Int16(clamping: Int(entity.playCount) + update.playCountDelta)
            }
            if let completionRate = update.completionRate {
                entity.completionRate = completionRate
            }
            if let replayRate = update.replayRate {
                entity.replayRate = replayRate
            }
            if let liked = update.liked {
                entity.liked = liked
            }
            if let hidden = update.hidden {
                entity.hidden = hidden
            }
            if let lastPlayedAt = update.lastPlayedAt {
                entity.lastPlayedAt = lastPlayedAt
            }

            try context.save()

            guard let model = VideoModel(entity: entity) else {
                throw VideoLibraryError.entityMissing
            }
            return model
        }
    }

    func recordFeedback(videoId: UUID, action: FeedbackModel.Action) async throws {
        try await performBackground { [self] context in
            guard try fetchVideo(in: context, id: videoId) != nil else {
                throw VideoLibraryError.entityMissing
            }
            let feedback = FeedbackEntity(context: context)
            feedback.id = UUID()
            feedback.videoId = videoId
            feedback.action = action.rawValue
            feedback.at = Date()
            try context.save()
        }
    }

    func toggleHidden(videoId: UUID, isHidden: Bool) async throws -> VideoModel {
        try await updateMetrics(
            PlaybackMetricUpdate(videoId: videoId, hidden: isHidden)
        )
    }

    func deleteVideo(videoId: UUID) async throws {
        try await performBackground { [self] context in
            guard let entity = try fetchVideo(in: context, id: videoId) else {
                throw VideoLibraryError.entityMissing
            }

            guard
                let filePath = entity.filePath,
                let thumbPath = entity.thumbPath
            else {
                context.delete(entity)
                try context.save()
                return
            }

            let fileURL = absoluteURL(from: filePath)
            let thumbURL = absoluteURL(from: thumbPath)

            context.delete(entity)
            try context.save()

            try? fileManager.removeItem(at: fileURL)
            try? fileManager.removeItem(at: thumbURL)
        }
    }

    func fetchRankingState(profileId: UUID) throws -> RankingStateModel {
        let request = RankingStateEntity.fetchRequest()
        request.predicate = NSPredicate(format: "profileId == %@", profileId as CVarArg)
        request.fetchLimit = 1
        if let entity = try persistence.viewContext.fetch(request).first,
           let model = RankingStateModel(entity: entity) {
            return model
        } else {
            let defaultModel = RankingStateModel(
                profileId: profileId,
                topicSuccess: [:],
                exploreRate: 0.15
            )
            try upsertRankingState(defaultModel)
            return defaultModel
        }
    }

    func upsertRankingState(_ model: RankingStateModel) throws {
        let context = persistence.viewContext
        let request = RankingStateEntity.fetchRequest()
        request.predicate = NSPredicate(format: "profileId == %@", model.profileId as CVarArg)
        let entity = try context.fetch(request).first ?? RankingStateEntity(context: context)
        entity.profileId = model.profileId
        entity.topicSuccessJSON = try self.encodeJSONString(model.topicSuccess)
        entity.exploreRate = model.exploreRate
        try context.save()
    }

    func videoFileURL(for video: VideoModel) -> URL {
        absoluteURL(from: video.filePath)
    }

    func thumbnailFileURL(for video: VideoModel) -> URL {
        absoluteURL(from: video.thumbPath)
    }

    // MARK: - Helpers

    private func performBackground<T>(
        _ work: @escaping (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            persistence.performBackgroundTask { context in
                do {
                    let result = try work(context)
                    continuation.resume(returning: result)
                } catch {
                    context.rollback()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchVideo(in context: NSManagedObjectContext, id: UUID) throws -> VideoEntity? {
        let request = VideoEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try jsonEncoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw VideoLibraryError.entityMissing
        }
        return string
    }

    private func encodeJSON(_ value: [String]) -> String {
        do {
            return try encodeJSONString(value as [String])
        } catch {
            return "[]"
        }
    }

    private func copyItemIfNeeded(from sourceURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            #if os(iOS)
            try? fileManager.setAttributes(
                [FileAttributeKey.protectionKey: FileProtectionType.complete],
                ofItemAtPath: destinationURL.path
            )
            #endif
        } catch {
            throw VideoLibraryError.fileOperationFailed(error)
        }
    }

    private func relativePath(for url: URL) -> String {
        let supportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = supportURL?.appendingPathComponent("MyTube", isDirectory: true)
        guard let base else { return url.path }
        let basePath = base.path
        guard url.path.hasPrefix(basePath) else { return url.path }
        var relative = String(url.path.dropFirst(basePath.count))
        if relative.first == "/" {
            relative.removeFirst()
        }
        return relative
    }

    private func absoluteURL(from relativePath: String) -> URL {
        if relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: relativePath)
        }
        let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("MyTube", isDirectory: true)
        return base?.appendingPathComponent(relativePath) ?? URL(fileURLWithPath: relativePath)
    }
}

private extension URL {
    var pathExtensionWithDot: String {
        guard !pathExtension.isEmpty else { return "" }
        return "." + pathExtension
    }
}
