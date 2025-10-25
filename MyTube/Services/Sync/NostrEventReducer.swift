//
//  NostrEventReducer.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import CoreData
import Foundation
import OSLog

struct SyncReducerContext {
    let persistence: PersistenceController
}

actor NostrEventReducer {
    private let context: SyncReducerContext
    private let logger = Logger(subsystem: "com.mytube", category: "NostrReducer")

    init(context: SyncReducerContext) {
        self.context = context
    }

    func handle(event: NostrEvent) async {
        guard let kind = MyTubeEventKind(rawValue: event.kind) else {
            logger.debug("Unhandled event kind \(event.kind, privacy: .public)")
            return
        }

        do {
            switch kind {
            case .familyLinkPointer:
                try await reduceFamilyLinkPointer(event)
            case .childFollowPointer:
                try await reduceFollowPointer(event)
            case .videoTombstone:
                try await reduceVideoTombstone(event)
            case .directMessage:
                try await reduceDirectMessage(event)
            }
        } catch {
            logger.error("Reducer failure for kind \(event.kind, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reduceFamilyLinkPointer(_ event: NostrEvent) async throws {
        guard let pairIdentifier = event.tagValue(for: "d") else {
            logger.warning("Family link pointer missing d tag")
            return
        }
        let metadata: [String: Any] = [
            "pubkey": event.pubkey,
            "tags": event.tags
        ]
        let metadataJSON = encodeMetadata(metadata)

        try await performBackgroundTask { context in
            let request = FamilyLinkEntity.fetchRequest()
            request.predicate = NSPredicate(format: "pairIdentifier == %@", pairIdentifier)
            request.fetchLimit = 1

            let entity: FamilyLinkEntity
            if let existing = try context.fetch(request).first {
                entity = existing
            } else {
                entity = FamilyLinkEntity(context: context)
                entity.pairIdentifier = pairIdentifier
            }

            entity.status = "pointer"
            entity.metadataJSON = metadataJSON
            entity.updatedAt = event.createdDate

            try context.save()
        }
    }

    private func reduceFollowPointer(_ event: NostrEvent) async throws {
        guard let identifier = event.tagValue(for: "d") else {
            logger.warning("Follow pointer missing d tag")
            return
        }

        let components = identifier.split(separator: ":")
        let follower = components.dropFirst().first.map(String.init) ?? ""
        let target = components.dropFirst(2).first.map(String.init) ?? ""

        let metadata: [String: Any] = [
            "pubkey": event.pubkey,
            "tags": event.tags
        ]
        let metadataJSON = encodeMetadata(metadata)

        try await performBackgroundTask { context in
            let request = FollowEntity.fetchRequest()
            request.predicate = NSPredicate(format: "followerChild == %@ AND targetChild == %@", follower, target)
            request.fetchLimit = 1

            let entity: FollowEntity
            if let existing = try context.fetch(request).first {
                entity = existing
            } else {
                entity = FollowEntity(context: context)
                entity.followerChild = follower
                entity.targetChild = target
            }

            entity.status = "pointer"
            entity.updatedAt = event.createdDate
            entity.metadataJSON = metadataJSON

            try context.save()
        }
    }

    private func reduceVideoTombstone(_ event: NostrEvent) async throws {
        guard let videoId = event.tagValue(for: "d") else {
            logger.warning("Video tombstone missing d tag")
            return
        }

        try await performBackgroundTask { context in
            let request = RemoteVideoEntity.fetchRequest()
            request.predicate = NSPredicate(format: "videoId == %@", videoId)
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                return
            }
            entity.status = "tombstoned"
            entity.lastSyncedAt = event.createdDate

            try context.save()
        }
    }

    private func reduceDirectMessage(_ event: NostrEvent) async throws {
        // TODO: Implement NIP-44 decoding and route to family link / follow / share reducers.
        logger.debug("Received DM event: \(event.id, privacy: .public)")
    }

    private func encodeMetadata(_ metadata: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    private func performBackgroundTask(_ work: @escaping (NSManagedObjectContext) throws -> Void) async throws {
        let backgroundContext = context.persistence.newBackgroundContext()
        try await withCheckedThrowingContinuation { continuation in
            backgroundContext.perform {
                do {
                    try work(backgroundContext)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
