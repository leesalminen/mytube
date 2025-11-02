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
    private let relationshipStore: RelationshipStore
    private let videoSharePublisher: VideoSharePublisher
    private let logger = Logger(subsystem: "com.mytube", category: "VideoShareCoordinator")
    private var contextObserver: NSObjectProtocol?

    private var pendingVideoIDs: Set<UUID> = []
    private var inflightVideoIDs: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []
    private var cachedFollowRelationships: [FollowModel] = []

    init(
        persistence: PersistenceController,
        keyStore: KeychainKeyStore,
        relationshipStore: RelationshipStore,
        videoSharePublisher: VideoSharePublisher
    ) {
        self.persistence = persistence
        self.keyStore = keyStore
        self.relationshipStore = relationshipStore
        self.videoSharePublisher = videoSharePublisher

        contextObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            Task { [weak self] in
                await self?.handleContextSave(notification)
            }
        }

        relationshipStore.followRelationshipsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] relationships in
                guard let self else { return }
                self.cachedFollowRelationships = relationships
                Task { await self.retryPendingShares() }
            }
            .store(in: &cancellables)

        relationshipStore.refreshAll()
    }

    deinit {
        if let observer = contextObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleContextSave(_ notification: Notification) async {
        guard let userInfo = notification.userInfo,
              let inserted = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject>,
              !inserted.isEmpty else {
            return
        }

        let videoObjectIDs = inserted
            .compactMap { object -> NSManagedObjectID? in
                if let video = object as? VideoEntity {
                    return video.objectID.isTemporaryID ? nil : video.objectID
                }
                return object.entity.name == "Video" ? object.objectID : nil
            }

        guard !videoObjectIDs.isEmpty else { return }

        for objectID in videoObjectIDs {
            await processVideo(objectID: objectID)
        }
    }

    private func processVideo(objectID: NSManagedObjectID) async {
        do {
            guard let video = try await fetchVideoModel(objectID: objectID) else { return }
            pendingVideoIDs.insert(video.id)
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
            guard let parentPair = try keyStore.fetchKeyPair(role: .parent) else {
                logger.info("Skipping share; parent identity missing.")
                return
            }
            guard let childPair = try keyStore.fetchKeyPair(role: .child(id: video.profileId)) else {
                logger.info("Skipping share; child identity missing for profile \(video.profileId.uuidString, privacy: .public).")
                return
            }

            let localParentHex = parentPair.publicKeyHex.lowercased()
            let childHex = childPair.publicKeyHex.lowercased()
            let ownerChildKey = childPair.publicKeyBech32 ?? childPair.publicKeyHex

            let followRelationships: [FollowModel]
            if cachedFollowRelationships.isEmpty {
                followRelationships = try relationshipStore.fetchFollowRelationships()
                cachedFollowRelationships = followRelationships
            } else {
                followRelationships = cachedFollowRelationships
            }
            let recipients = recipientParents(
                from: followRelationships,
                targetChildHex: childHex,
                localParentHex: localParentHex
            )

            guard !recipients.isEmpty else {
                logger.debug("No active followers for video \(video.id.uuidString, privacy: .public); deferring share.")
                logFollowDiagnostics(targetChildHex: childHex, localParentHex: localParentHex)
                pendingVideoIDs.insert(video.id)
                return
            }

            var failedRecipients: [String] = []
            for recipientHex in recipients {
                let recipientKey = ParentIdentityKey(string: recipientHex)?.displayValue ?? recipientHex
                do {
                    try await videoSharePublisher.share(
                        video: video,
                        ownerChildNpub: ownerChildKey,
                        recipientPublicKey: recipientKey
                    )
                } catch {
                    logger.error("Failed sharing video \(video.id.uuidString, privacy: .public) to \(recipientHex.prefix(8), privacy: .public)… \(error.localizedDescription, privacy: .public)")
                    failedRecipients.append(recipientHex)
                }
            }

            if failedRecipients.isEmpty {
                pendingVideoIDs.remove(video.id)
                logger.info("Shared video \(video.id.uuidString, privacy: .public) with \(recipients.count) follower(s).")
            } else {
                pendingVideoIDs.insert(video.id)
                logger.error("Automatic share for video \(video.id.uuidString, privacy: .public) had \(failedRecipients.count) failure(s).")
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

    private func recipientParents(
        from relationships: [FollowModel],
        targetChildHex: String,
        localParentHex: String
    ) -> [String] {
        var recipients: Set<String> = []
        for follow in relationships {
            let isTarget = follow.targetChildHex()?.caseInsensitiveCompare(targetChildHex) == .orderedSame
            let isFollower = follow.followerChildHex()?.caseInsensitiveCompare(targetChildHex) == .orderedSame
            guard isTarget || isFollower else { continue }
            guard follow.approvedFrom, follow.approvedTo else { continue }
            guard follow.status != .revoked, follow.status != .blocked else { continue }

            var parentKeys = follow.remoteParentKeys(localParentHex: localParentHex)
            if parentKeys.isEmpty,
               let lastBy = follow.lastMessage?.by,
               let normalized = ParentIdentityKey(string: lastBy)?.hex.lowercased(),
               normalized.caseInsensitiveCompare(localParentHex) != .orderedSame {
                parentKeys = [normalized]
            }

            for parentHex in parentKeys {
                recipients.insert(parentHex.lowercased())
            }
        }
        return Array(recipients)
    }

    private func logFollowDiagnostics(targetChildHex: String, localParentHex: String) {
        guard !cachedFollowRelationships.isEmpty else { return }
        for follow in cachedFollowRelationships {
            let isTarget = follow.targetChildHex()?.caseInsensitiveCompare(targetChildHex) == .orderedSame
            let isFollower = follow.followerChildHex()?.caseInsensitiveCompare(targetChildHex) == .orderedSame
            guard isTarget || isFollower else { continue }
            let remoteParents = follow.remoteParentKeys(localParentHex: localParentHex)
            logger.debug(
                """
                Follow candidate follower \(follow.followerChild, privacy: .public) \
                target \(follow.targetChild, privacy: .public) status \(follow.status.rawValue, privacy: .public) \
                approvedFrom \(follow.approvedFrom) approvedTo \(follow.approvedTo) \
                remoteParents \(remoteParents)
                """
            )
        }
    }
}
