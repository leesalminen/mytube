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
    private let parentalControlsStore: ParentalControlsStore
    private let contentScanner: VideoContentScanner
    private let fileManager: FileManager
    private let jsonEncoder = JSONEncoder()

    init(
        persistence: PersistenceController,
        storagePaths: StoragePaths,
        parentalControlsStore: ParentalControlsStore,
        contentScanner: VideoContentScanner,
        fileManager: FileManager = .default
    ) {
        self.persistence = persistence
        self.storagePaths = storagePaths
        self.parentalControlsStore = parentalControlsStore
        self.contentScanner = contentScanner
        self.fileManager = fileManager
    }

    func createVideo(
        request: VideoCreationRequest,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> VideoModel {
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

        let initialModel = try await performBackground { [self] context in
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
            entity.approvalStatus = VideoModel.ApprovalStatus.scanning.rawValue
            entity.approvedAt = nil
            entity.approvedByParentKey = nil
            entity.scanResults = nil
            entity.scanCompletedAt = nil

            try context.save()

            guard let model = VideoModel(entity: entity) else {
                throw VideoLibraryError.entityMissing
            }
            return model
        }

        report(progress, message: "Starting content scan…")
        let scanResult: ContentScanResult?
        if parentalControlsStore.enableContentScanning {
            scanResult = await contentScanner.scan(url: videoFileURL, progress: progress)
        } else {
            scanResult = nil
        }

        let updatedModel = try await performBackground { [self] context in
            guard let entity = try fetchVideo(in: context, id: videoId) else {
                throw VideoLibraryError.entityMissing
            }

            if let scanResult {
                entity.scanResults = try? encodeJSONString(scanResult)
                entity.scanCompletedAt = Date()
                entity.approvalStatus = resolveApprovalStatus(for: scanResult).rawValue
            } else {
                entity.scanResults = nil
                entity.scanCompletedAt = Date()
                entity.approvalStatus = resolveApprovalStatus(for: nil).rawValue
            }

            if entity.approvalStatus == VideoModel.ApprovalStatus.approved.rawValue {
                entity.approvedAt = Date()
            }

            try context.save()

            guard let model = VideoModel(entity: entity) else {
                throw VideoLibraryError.entityMissing
            }
            return model
        }

        report(progress, message: "Scan complete.")
        try? FileManager.default.removeItem(at: request.sourceURL)
        try? FileManager.default.removeItem(at: request.thumbnailURL)

        return updatedModel
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

    @discardableResult
    func markVideoReported(
        videoId: UUID,
        reason: ReportReason,
        reportedAt: Date = Date()
    ) async throws -> VideoModel {
        try await performBackground { [self] context in
            guard let entity = try fetchVideo(in: context, id: videoId) else {
                throw VideoLibraryError.entityMissing
            }

            entity.reportedAt = reportedAt
            entity.reportReason = reason.rawValue
            entity.hidden = true

            try context.save()

            guard let model = VideoModel(entity: entity) else {
                throw VideoLibraryError.entityMissing
            }
            return model
        }
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

    private func resolveApprovalStatus(for scanResult: ContentScanResult?) -> VideoModel.ApprovalStatus {
        if parentalControlsStore.requiresVideoApproval == false {
            return .approved
        }

        guard let scanResult else {
            return .pending
        }

        if let autoRejectThreshold = parentalControlsStore.autoRejectThreshold,
           scanResult.confidence < autoRejectThreshold {
            return .rejected
        }

        let pendingThreshold = 0.65
        if scanResult.confidence < pendingThreshold {
            return .pending
        }

        return .approved
    }

    private func report(_ handler: (@Sendable (String) -> Void)?, message: String) {
        guard let handler else { return }
        DispatchQueue.main.async {
            handler(message)
        }
    }
}

private extension URL {
    var pathExtensionWithDot: String {
        guard !pathExtension.isEmpty else { return "" }
        return "." + pathExtension
    }
}
