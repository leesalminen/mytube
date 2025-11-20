//
//  VideoShareCoordinator.swift
//  MyTube
//
//  Created by Codex on 11/30/25.
//

import Combine
import CoreData
import Foundation
import OSLog

@MainActor
final class VideoShareCoordinator {
    private let persistence: PersistenceController
    private let keyStore: KeychainKeyStore
    private let videoSharePublisher: VideoSharePublisher
    private let marmotShareService: MarmotShareService
    private let parentalControlsStore: ParentalControlsStore
    private let logger = Logger(subsystem: "com.mytube", category: "VideoShareCoordinator")
    private var contextObserver: NSObjectProtocol?

    private var pendingVideoIDs: Set<UUID> = []
    private var inflightVideoIDs: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    enum PublishError: Error {
        case videoMissing
        case invalidState
        case parentKeyMissing
    }

    init(
        persistence: PersistenceController,
        keyStore: KeychainKeyStore,
        videoSharePublisher: VideoSharePublisher,
        marmotShareService: MarmotShareService,
        parentalControlsStore: ParentalControlsStore
    ) {
        self.persistence = persistence
        self.keyStore = keyStore
        self.videoSharePublisher = videoSharePublisher
        self.marmotShareService = marmotShareService
        self.parentalControlsStore = parentalControlsStore

        contextObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            Task { [weak self] in
                await self?.handleContextSave(notification)
            }
        }

        // Relationship store removed - using MDK groups directly
        // Group changes trigger via NotificationCenter.marmotStateDidChange
        NotificationCenter.default.addObserver(
            forName: .marmotStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.retryPendingShares()
            }
        }
    }

    deinit {
        if let observer = contextObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleContextSave(_ notification: Notification) async {
        guard let userInfo = notification.userInfo else { return }
        let inserted = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
        let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []

        let videoObjectIDs = Set(
            inserted
                .compactMap(videoObjectID(from:)) +
                updated.compactMap(videoObjectID(from:))
        )

        guard !videoObjectIDs.isEmpty else { return }

        for objectID in videoObjectIDs {
            await processVideo(objectID: objectID)
        }
    }

    private func processVideo(objectID: NSManagedObjectID) async {
        do {
            guard let video = try await fetchVideoModel(objectID: objectID) else { return }
            pendingVideoIDs.insert(video.id)

            if video.approvalStatus == .rejected {
                pendingVideoIDs.remove(video.id)
                logger.info("Video \(video.id.uuidString, privacy: .public) rejected; skipping share.")
                return
            }

            guard video.approvalStatus == .approved else {
                if parentalControlsStore.requiresVideoApproval {
                    logger.info("Video \(video.id.uuidString, privacy: .public) awaiting approval (\(video.approvalStatus.rawValue, privacy: .public)).")
                } else {
                    logger.info("Skipping share for video \(video.id.uuidString, privacy: .public); status \(video.approvalStatus.rawValue, privacy: .public).")
                }
                return
            }

            await share(video: video)
        } catch {
            logger.error("Failed to prepare video share: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchVideoModel(objectID: NSManagedObjectID) async throws -> VideoModel? {
        try await withCheckedThrowingContinuation { continuation in
            persistence.viewContext.perform {
                do {
                    guard let entity = try self.persistence.viewContext.existingObject(with: objectID) as? VideoEntity else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: VideoModel(entity: entity))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchVideoModel(videoId: UUID) async throws -> VideoModel? {
        try await withCheckedThrowingContinuation { continuation in
            persistence.viewContext.perform {
                do {
                    let request = VideoEntity.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", videoId as CVarArg)
                    request.fetchLimit = 1
                    guard let entity = try self.persistence.viewContext.fetch(request).first else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: VideoModel(entity: entity))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func share(video: VideoModel) async {
        if inflightVideoIDs.contains(video.id) {
            return
        }
        inflightVideoIDs.insert(video.id)
        defer { inflightVideoIDs.remove(video.id) }

        do {
            guard video.approvalStatus == .approved else {
                logger.info("Share skipped for \(video.id.uuidString, privacy: .public); approval status \(video.approvalStatus.rawValue, privacy: .public)")
                return
            }
            guard let parentPair = try keyStore.fetchKeyPair(role: .parent) else {
                logger.info("Skipping share; parent identity missing.")
                return
            }
            
            // Children no longer have keys - use profile ID as identifier
            let childProfileId = video.profileId.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let ownerChildKey = childProfileId  // Use profile ID instead of child pubkey

            // Get the group ID for this child's profile
            guard let profile = try? persistence.viewContext.fetch(ProfileEntity.fetchRequest()).first(where: { $0.id == video.profileId }),
                  let groupId = profile.mlsGroupId else {
                logger.debug("No Marmot group for video \(video.id.uuidString, privacy: .public); deferring share.")
                pendingVideoIDs.insert(video.id)
                return
            }

            logger.info("📤 Sharing video \(video.id.uuidString, privacy: .public) to group \(groupId.prefix(16), privacy: .public)... for profile \(video.profileId.uuidString, privacy: .public)")
            let groupIds = [groupId]

            let shareMessage = try await videoSharePublisher.makeShareMessage(
                video: video,
                ownerChildNpub: ownerChildKey
            )

            var failedGroups: [String] = []
            for groupId in groupIds {
                do {
                    _ = try await marmotShareService.publishVideoShare(
                        message: shareMessage,
                        mlsGroupId: groupId
                    )
                } catch {
                    logger.error("Failed sharing video \(video.id.uuidString, privacy: .public) to group \(groupId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failedGroups.append(groupId)
                }
            }

            if failedGroups.isEmpty {
                pendingVideoIDs.remove(video.id)
                logger.info("Shared video \(video.id.uuidString, privacy: .public) with \(groupIds.count) Marmot group(s).")
            } else {
                pendingVideoIDs.insert(video.id)
                logger.error("Automatic share for video \(video.id.uuidString, privacy: .public) failed for \(failedGroups.count) group(s).")
            }
        } catch {
            pendingVideoIDs.insert(video.id)
            logger.error("Share attempt failed for video \(video.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func retryPendingShares() async {
        guard !pendingVideoIDs.isEmpty else { return }
        let candidates = pendingVideoIDs
        for videoId in candidates {
            do {
                guard let video = try await fetchVideoModel(videoId: videoId) else {
                    pendingVideoIDs.remove(videoId)
                    continue
                }
                await share(video: video)
            } catch {
                logger.error("Retry share failed for video \(videoId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func publishVideo(_ videoId: UUID) async throws {
        guard let parentKey = try keyStore.fetchKeyPair(role: .parent)?.publicKeyHex.lowercased() else {
            throw PublishError.parentKeyMissing
        }

        let video = try await markVideoAsApproved(videoId: videoId, parentKey: parentKey)
        pendingVideoIDs.insert(video.id)
        await share(video: video)
    }

    func markVideoAsApproved(videoId: UUID, parentKey: String) async throws -> VideoModel {
        try await withCheckedThrowingContinuation { continuation in
            persistence.performBackgroundTask { context in
                do {
                    let request = VideoEntity.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", videoId as CVarArg)
                    request.fetchLimit = 1
                    guard let entity = try context.fetch(request).first else {
                        continuation.resume(throwing: PublishError.videoMissing)
                        return
                    }
                    guard let current = VideoModel(entity: entity),
                          current.approvalStatus == .pending else {
                        continuation.resume(throwing: PublishError.invalidState)
                        return
                    }

                    entity.approvalStatus = VideoModel.ApprovalStatus.approved.rawValue
                    entity.approvedAt = Date()
                    entity.approvedByParentKey = parentKey

                    try context.save()
                    guard let updated = VideoModel(entity: entity) else {
                        continuation.resume(throwing: PublishError.videoMissing)
                        return
                    }
                    continuation.resume(returning: updated)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func videoObjectID(from object: NSManagedObject) -> NSManagedObjectID? {
        if let video = object as? VideoEntity {
            return video.objectID.isTemporaryID ? nil : video.objectID
        }
        return object.entity.name == "Video" ? object.objectID : nil
    }

    // Follow relationship logic removed - using MDK groups directly
}

extension VideoShareCoordinator.PublishError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .videoMissing:
            return "Could not locate the video to publish."
        case .invalidState:
            return "This video is not waiting for approval."
        case .parentKeyMissing:
            return "Parent identity is missing; add a parent key to approve videos."
        }
    }
}
