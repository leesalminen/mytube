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
    private let dmDecoder: JSONDecoder
    private let dmEncoder: JSONEncoder

    init(context: SyncReducerContext) {
        self.context = context
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        dmDecoder = decoder

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        dmEncoder = encoder
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
            case .directMessage:
                try await reduceDirectMessage(event)
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
            payload = try dmDecoder.decode(ProfileMetadataPayload.self, from: data)
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
            pointerMessage = try? dmDecoder.decode(FollowMessage.self, from: data)
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
                Follow pointer DM content follower \(followerCanonical, privacy: .public) \
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

    private func reduceDirectMessage(_ event: NostrEvent) async throws {
        guard
            let senderPublicKey = Data(hexString: event.pubkey)
        else {
            logger.error("DM \(event.idHex, privacy: .public) has invalid sender public key.")
            return
        }

        guard let parentKeyPair = try context.keyStore.fetchKeyPair(role: .parent) else {
            logger.warning("No parent key configured. Skipping DM \(event.idHex, privacy: .public).")
            return
        }

        let plaintext: Data
        do {
            plaintext = try context.cryptoService.decryptDirectMessage(
                event.content(),
                recipientPrivateKeyData: parentKeyPair.privateKeyData,
                senderPublicKeyXOnly: senderPublicKey
            )
        } catch {
            logger.error("Failed to decrypt DM \(event.idHex, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let baseEnvelope: DirectMessageEnvelope
        do {
            baseEnvelope = try dmDecoder.decode(DirectMessageEnvelope.self, from: plaintext)
        } catch {
            logger.error("Failed to decode DM envelope for \(event.idHex, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let kind = DirectMessageKind(rawValue: baseEnvelope.t) else {
            logger.warning("Unsupported DM kind \(baseEnvelope.t, privacy: .public)")
            return
        }

        switch kind {
        case .follow:
            let payload = try dmDecoder.decode(FollowMessage.self, from: plaintext)
            try await reduceFollowDM(payload)
        case .videoShare:
            let payload = try dmDecoder.decode(VideoShareMessage.self, from: plaintext)
            try await reduceVideoShareDM(payload)
        case .videoRevoke:
            let payload: VideoLifecycleMessage = try dmDecoder.decode(VideoLifecycleMessage.self, from: plaintext)
            try await reduceVideoRevokeDM(payload)
        case .videoDelete:
            let payload: VideoLifecycleMessage = try dmDecoder.decode(VideoLifecycleMessage.self, from: plaintext)
            try await reduceVideoDeleteDM(payload)
        case .like:
            let payload = try dmDecoder.decode(LikeMessage.self, from: plaintext)
            await reduceLikeDM(payload)
        case .report:
            let payload = try dmDecoder.decode(ReportMessage.self, from: plaintext)
            await reduceReportDM(payload)
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

    private func reduceLikeDM(_ message: LikeMessage) async {
        await context.likeStore.processIncomingLike(message)
    }

    private func reduceReportDM(_ message: ReportMessage) async {
        let timestamp = Date(timeIntervalSince1970: message.ts)
        let reason = ReportReason(rawValue: message.reason) ?? .other
        let reporterHex = canonicalKey(message.by)
        let subjectHex = canonicalKey(message.subjectChild)
        let localParentHex = localParentPublicKey()
        let reporterIsLocal = reporterHex == localParentHex
        let subjectIsLocalChild = localChildHexKeys().contains(subjectHex)

        do {
            let stored = try await MainActor.run {
                try await self.context.reportStore.ingestReportMessage(
                    message,
                    isOutbound: reporterIsLocal,
                    createdAt: timestamp,
                    deliveredAt: reporterIsLocal ? timestamp : nil,
                    defaultStatus: reporterIsLocal ? .acknowledged : .pending,
                    action: nil
                )
            }

            if reporterIsLocal {
                await handleReporterSideEffects(for: message, reason: reason, timestamp: timestamp, stored: stored)
            }

            if subjectIsLocalChild {
                await handleSubjectSideEffects(for: message, reason: reason, timestamp: timestamp, stored: stored)
            }
        } catch {
            logger.error("Failed to persist report DM for video \(message.videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleReporterSideEffects(
        for message: ReportMessage,
        reason: ReportReason,
        timestamp: Date,
        stored: ReportModel
    ) async {
        do {
            _ = try context.remoteVideoStore.markVideoAsBlocked(
                videoId: message.videoId,
                reason: reason.rawValue,
                storagePaths: context.storagePaths,
                timestamp: timestamp
            )
        } catch {
            logger.error("Failed to mark reported video \(message.videoId, privacy: .public) as blocked: \(error.localizedDescription, privacy: .public)")
        }

        let action = stored.actionTaken == .none ? .reportOnly : stored.actionTaken
        do {
            try await MainActor.run {
                try await self.context.reportStore.updateStatus(
                    reportId: stored.id,
                    status: .actioned,
                    action: action,
                    lastActionAt: timestamp
                )
            }
        } catch {
            logger.error("Failed updating report status after reporter side effects: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleSubjectSideEffects(
        for message: ReportMessage,
        reason: ReportReason,
        timestamp: Date,
        stored: ReportModel
    ) async {
        guard let uuid = UUID(uuidString: message.videoId) else {
            logger.warning("Reported video id \(message.videoId, privacy: .public) is not a valid UUID; skipping local marking.")
            return
        }

        do {
            _ = try await context.videoLibrary.markVideoReported(
                videoId: uuid,
                reason: reason,
                reportedAt: timestamp
            )
        } catch {
            logger.error("Failed to mark local video \(message.videoId, privacy: .public) as reported: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try await MainActor.run {
                try await self.context.reportStore.updateStatus(
                    reportId: stored.id,
                    status: .actioned,
                    action: .deleted,
                    lastActionAt: timestamp
                )
            }
        } catch {
            logger.error("Failed updating report status after subject side effects: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? dmEncoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func reduceFollowDM(_ message: FollowMessage) async throws {
        guard let parentPair = try context.keyStore.fetchKeyPair(role: .parent) else {
            logger.warning("Follow DM ignored; parent identity missing")
            return
        }
        guard let remoteParent = ParentIdentityKey(string: message.by) else {
            logger.warning("Follow DM has invalid parent key")
            return
        }

        let updatedAt = Date(timeIntervalSince1970: message.ts)
        let messageDate = Date(timeIntervalSince1970: message.ts)
        let finalStatus = message.status

        let normalizedMessage = FollowMessage(
            followerChild: message.followerChild,
            targetChild: message.targetChild,
            approvedFrom: message.approvedFrom,
            approvedTo: message.approvedTo,
            status: finalStatus,
            by: message.by,
            timestamp: messageDate
        )

        do {
            _ = try context.relationshipStore.upsertFollow(
                message: normalizedMessage,
                updatedAt: updatedAt,
                participantKeys: [message.by]
            )
        } catch {
            logger.error("Failed to persist follow DM: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reduceVideoShareDM(_ message: VideoShareMessage) async throws {
        let metadataJSON = encodeJSON(message)
        let cryptoJSON = encodeJSON(message.crypto)
        let createdAt = message.meta?.createdAtDate ?? Date(timeIntervalSince1970: message.ts)
        let expiresAt = message.policy?.expiresAtDate
        let lastSynced = Date(timeIntervalSince1970: message.ts)

        try await performBackgroundTask { context in
            let request = RemoteVideoEntity.fetchRequest()
            request.predicate = NSPredicate(format: "videoId == %@", message.videoId)
            request.fetchLimit = 1

            let (entity, isNew): (RemoteVideoEntity, Bool) = {
                if let existing = (try? context.fetch(request))?.first {
                    return (existing, false)
                } else {
                    let newEntity = RemoteVideoEntity(context: context)
                    newEntity.videoId = message.videoId
                    return (newEntity, true)
                }
            }()

            let previousStatus = entity.status ?? RemoteVideoModel.Status.available.rawValue
            let previousMediaPath = entity.localMediaPath
            let previousThumbPath = entity.localThumbPath
            let previousDownloadedAt = entity.lastDownloadedAt

            entity.ownerChild = message.ownerChild
            entity.title = message.meta?.title ?? "Untitled"
            entity.duration = message.meta?.duration ?? 0
            entity.createdAt = createdAt
            entity.blobURL = message.blob.url
            entity.thumbURL = message.thumb.url
            entity.wrappedKeyJSON = cryptoJSON
            entity.visibility = message.policy?.visibility ?? "followers"
            entity.expiresAt = expiresAt
            if previousStatus == RemoteVideoModel.Status.downloaded.rawValue {
                entity.status = previousStatus
                entity.localMediaPath = previousMediaPath
                entity.localThumbPath = previousThumbPath
                entity.lastDownloadedAt = previousDownloadedAt
            } else {
                entity.status = RemoteVideoModel.Status.available.rawValue
                if !isNew {
                    entity.localMediaPath = nil
                    entity.localThumbPath = nil
                    entity.lastDownloadedAt = nil
                }
            }
            entity.downloadError = nil
            entity.lastSyncedAt = lastSynced
            entity.metadataJSON = metadataJSON

            try context.save()
        }
    }

    private func reduceVideoRevokeDM(_ message: VideoLifecycleMessage) async throws {
        let metadataJSON = encodeJSON(message)
        let syncedAt = Date(timeIntervalSince1970: message.ts)
        let videoId = message.videoId
        let logger = self.logger

        try await performBackgroundTask { [metadataJSON, syncedAt, videoId, logger] context in
            let request = RemoteVideoEntity.fetchRequest()
            request.predicate = NSPredicate(format: "videoId == %@", videoId)
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                logger.warning("Received revoke for unknown video \(videoId)")
                return
            }

            entity.status = RemoteVideoModel.Status.revoked.rawValue
            entity.localMediaPath = nil
            entity.localThumbPath = nil
            entity.lastDownloadedAt = nil
            entity.downloadError = nil
            entity.lastSyncedAt = syncedAt
            entity.metadataJSON = metadataJSON

            try context.save()
        }
    }

    private func reduceVideoDeleteDM(_ message: VideoLifecycleMessage) async throws {
        let metadataJSON = encodeJSON(message)
        let syncedAt = Date(timeIntervalSince1970: message.ts)
        let videoId = message.videoId
        let logger = self.logger

        try await performBackgroundTask { [metadataJSON, syncedAt, videoId, logger] context in
            let request = RemoteVideoEntity.fetchRequest()
            request.predicate = NSPredicate(format: "videoId == %@", videoId)
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                logger.warning("Received delete for unknown video \(videoId)")
                return
            }

            entity.status = RemoteVideoModel.Status.deleted.rawValue
            entity.localMediaPath = nil
            entity.localThumbPath = nil
            entity.lastDownloadedAt = nil
            entity.downloadError = nil
            entity.lastSyncedAt = syncedAt
            entity.metadataJSON = metadataJSON

            try context.save()
        }
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

    private func localParentPublicKey() -> String? {
        guard let pair = try? context.keyStore.fetchKeyPair(role: .parent) else {
            return nil
        }
        return pair.publicKeyHex.lowercased()
    }

    private func localChildHexKeys() -> Set<String> {
        guard let identifiers = try? context.keyStore.childKeyIdentifiers() else {
            return []
        }
        var keys: Set<String> = []
        for identifier in identifiers {
            if let pair = try? context.keyStore.fetchKeyPair(role: .child(id: identifier)) {
                keys.insert(pair.publicKeyHex.lowercased())
            }
        }
        return keys
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
