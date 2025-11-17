//
//  NostrEventReducer.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import CoreData
import Foundation
import OSLog
import NostrSDK

struct SyncReducerContext {
    let persistence: PersistenceController
    let keyStore: KeychainKeyStore
    let cryptoService: CryptoEnvelopeService
    let relationshipStore: RelationshipStore
    let parentProfileStore: ParentProfileStore
    let childProfileStore: ChildProfileStore
    let likeStore: LikeStore
    let reportStore: ReportStore
    let remoteVideoStore: RemoteVideoStore
    let videoLibrary: VideoLibrary
    let storagePaths: StoragePaths
}

actor NostrEventReducer {
    private let context: SyncReducerContext
    private let logger = Logger(subsystem: "com.mytube", category: "NostrReducer")
    private let jsonDecoder: JSONDecoder

    init(context: SyncReducerContext) {
        self.context = context
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        jsonDecoder = decoder
    }

    func handle(event: NostrEvent) async {
        let kindCode = Int(event.kind().asU16())
        guard let kind = MyTubeEventKind(rawValue: kindCode) else {
            logger.debug("Unhandled event kind \(kindCode, privacy: .public)")
            return
        }

        do {
            switch kind {
            case .metadata:
                try await reduceMetadata(event)
            case .childFollowPointer:
                try await reduceFollowPointer(event)
            case .videoTombstone:
                try await reduceVideoTombstone(event)
            }
        } catch {
            logger.error("Reducer failure for kind \(kindCode, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reduceMetadata(_ event: NostrEvent) async throws {
        guard let data = event.content().data(using: .utf8) else {
            logger.warning("Metadata event has empty content")
            return
        }

        let payload: ProfileMetadataPayload
        do {
            payload = try jsonDecoder.decode(ProfileMetadataPayload.self, from: data)
        } catch {
            logger.warning("Failed to decode parent metadata \(event.idHex, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        func decodeWrapKey(_ value: String) -> Data? {
            if let data = Data(base64Encoded: value) {
                return data
            }
            var base64 = value
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padding = 4 - (base64.count % 4)
            if padding > 0 && padding < 4 {
                base64.append(String(repeating: "=", count: padding))
            }
            if let data = Data(base64Encoded: base64) {
                return data
            }
            return Data(hexString: value)
        }

        let updatedAt = event.createdDate
        let canonicalPubkey = canonicalKey(event.pubkey)

        let trimmedWrapKey = payload.wrapKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedWrapKey.isEmpty {
            var wrapKeyData: Data?
            wrapKeyData = decodeWrapKey(trimmedWrapKey)
            if wrapKeyData == nil {
                logger.warning("Metadata wrap key invalid for \(event.pubkey, privacy: .public)")
            }

            try await performBackgroundTask { context in
                _ = try self.context.parentProfileStore.upsertProfile(
                    publicKey: canonicalPubkey,
                    name: payload.name,
                    displayName: payload.displayName,
                    about: payload.about,
                    pictureURLString: payload.picture,
                    wrapPublicKey: wrapKeyData,
                    updatedAt: updatedAt,
                    in: context
                )
            }
        } else {
            try await performBackgroundTask { context in
                _ = try self.context.childProfileStore.upsertProfile(
                    publicKey: canonicalPubkey,
                    name: payload.name,
                    displayName: payload.displayName,
                    about: payload.about,
                    pictureURLString: payload.picture,
                    updatedAt: updatedAt,
                    in: context
                )
            }
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

        let pointerMessage: FollowMessage?
        if let data = event.content().data(using: .utf8) {
            pointerMessage = try? jsonDecoder.decode(FollowMessage.self, from: data)
        } else {
            pointerMessage = nil
        }

        let eventCreatedDate = event.createdDate

        if let message = pointerMessage {
            let messageDate = Date(timeIntervalSince1970: message.ts)
            let followerCanonical = canonicalKey(message.followerChild)
            let targetCanonical = canonicalKey(message.targetChild)

            logger.debug(
                """
                Follow pointer message follower \(followerCanonical, privacy: .public) \
                target \(targetCanonical, privacy: .public) approvedFrom \(message.approvedFrom) \
                approvedTo \(message.approvedTo) status \(message.status, privacy: .public)
                """
            )

            if let existing = try? context.relationshipStore.followRelationship(follower: followerCanonical, target: targetCanonical),
               existing.updatedAt > messageDate {
                return
            }

            let normalizedMessage = FollowMessage(
                followerChild: message.followerChild,
                targetChild: message.targetChild,
                approvedFrom: message.approvedFrom,
                approvedTo: message.approvedTo,
                status: message.status,
                by: message.by,
                timestamp: messageDate
            )

            do {
                _ = try context.relationshipStore.upsertFollow(
                    message: normalizedMessage,
                    updatedAt: messageDate,
                    participantKeys: [message.by]
                )
            } catch {
                logger.error("Failed to upsert follow from pointer message: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        let followerCanonical = canonicalKey(follower)
        let targetCanonical = canonicalKey(target)

        logger.debug(
            """
            Follow pointer event follower \(followerCanonical, privacy: .public) \
            target \(targetCanonical, privacy: .public) pubkey \(event.pubkey, privacy: .public)
            """
        )

        if followerCanonical.isEmpty || targetCanonical.isEmpty {
            logger.warning("Follow pointer missing canonical keys")
            return
        }

        if let existing = try? context.relationshipStore.followRelationship(follower: followerCanonical, target: targetCanonical),
           existing.updatedAt >= eventCreatedDate {
            return
        }

        let placeholderMessage = FollowMessage(
            followerChild: followerCanonical,
            targetChild: targetCanonical,
            approvedFrom: false,
            approvedTo: false,
            status: FollowModel.Status.pending.rawValue,
            by: event.pubkey,
            timestamp: eventCreatedDate
        )

        do {
            _ = try context.relationshipStore.upsertFollow(
                message: placeholderMessage,
                updatedAt: eventCreatedDate,
                participantKeys: [event.pubkey]
            )
        } catch {
            logger.error("Failed to upsert placeholder follow from pointer: \(error.localizedDescription, privacy: .public)")
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

    private func encodeMetadata(_ metadata: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    private func canonicalKey(_ value: String) -> String {
        if let parent = ParentIdentityKey(string: value) {
            return parent.hex.lowercased()
        }
        if let data = Data(hexString: value), data.count == 32 {
            return data.hexEncodedString().lowercased()
        }
        return value.lowercased()
    }

    private func performBackgroundTask(_ work: @escaping @Sendable (NSManagedObjectContext) throws -> Void) async throws {
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
