//
//  NostrEventReducer.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import CoreData
import CryptoKit
import Foundation
import OSLog

struct SyncReducerContext {
    let persistence: PersistenceController
    let keyStore: KeychainKeyStore
    let cryptoService: CryptoEnvelopeService
}

// MARK: - DM Models

private struct DMEnvelope: Decodable {
    let t: String
}

private enum DMKind: String {
    case familyLink = "mytube/family_link"
    case follow = "mytube/follow"
    case videoShare = "mytube/video_share"
    case videoRevoke = "mytube/video_revoke"
    case videoDelete = "mytube/video_delete"
    case like = "mytube/like"
    case report = "mytube/report"
}

private struct FamilyLinkMessage: Codable {
    let t: String
    let pair: [String]
    let status: String
    let by: String
    let ts: Double
}

private struct FollowMessage: Codable {
    let t: String
    let followerChild: String
    let targetChild: String
    let approvedFrom: Bool
    let approvedTo: Bool
    let status: String
    let by: String
    let ts: Double

    private enum CodingKeys: String, CodingKey {
        case t
        case followerChild = "follower_child"
        case targetChild = "target_child"
        case approvedFrom
        case approvedTo
        case status
        case by
        case ts
    }
}

private struct VideoShareMessage: Codable {
    struct Meta: Codable {
        let title: String?
        let duration: Double?
        let createdAt: Double?

        private enum CodingKeys: String, CodingKey {
            case title
            case duration = "dur"
            case createdAt = "created_at"
        }

        var createdAtDate: Date? {
            guard let createdAt else { return nil }
            return Date(timeIntervalSince1970: createdAt)
        }
    }

    struct Blob: Codable {
        let url: String
        let mime: String
        let length: Int?

        private enum CodingKeys: String, CodingKey {
            case url
            case mime
            case length = "len"
        }
    }

    struct Crypto: Codable {
        let algMedia: String
        let nonceMedia: String
        let algWrap: String
        let wrap: Wrap

        struct Wrap: Codable {
            let ephemeralPub: String
            let wrapSalt: String
            let wrapNonce: String
            let keyWrapped: String

            private enum CodingKeys: String, CodingKey {
                case ephemeralPub = "ephemeral_pub"
                case wrapSalt = "wrap_salt"
                case wrapNonce = "wrap_nonce"
                case keyWrapped = "key_wrapped"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case algMedia = "alg_media"
            case nonceMedia = "nonce_media"
            case algWrap = "alg_wrap"
            case wrap
        }
    }

    struct Policy: Codable {
        let visibility: String?
        let expiresAt: Double?
        let version: Int?

        private enum CodingKeys: String, CodingKey {
            case visibility
            case expiresAt = "expires_at"
            case version
        }

        var expiresAtDate: Date? {
            guard let expiresAt else { return nil }
            return Date(timeIntervalSince1970: expiresAt)
        }
    }

    let t: String
    let videoId: String
    let ownerChild: String
    let meta: Meta?
    let blob: Blob
    let thumb: Blob
    let crypto: Crypto
    let policy: Policy?
    let by: String
    let ts: Double

    private enum CodingKeys: String, CodingKey {
        case t
        case videoId = "video_id"
        case ownerChild = "owner_child"
        case meta
        case blob
        case thumb
        case crypto
        case policy
        case by
        case ts
    }
}

private struct VideoLifecycleMessage: Codable {
    let t: String
    let videoId: String
    let reason: String?
    let by: String
    let ts: Double

    private enum CodingKeys: String, CodingKey {
        case t
        case videoId = "video_id"
        case reason
        case by
        case ts
    }
}

// MARK: - Helpers

private extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }

        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard nextIndex <= cleaned.endIndex else { return nil }
            let byteString = cleaned[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
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
        guard let ciphertext = Data(base64Encoded: event.content, options: .ignoreUnknownCharacters) else {
            logger.error("DM \(event.id, privacy: .public) content is not valid base64.")
            return
        }

        guard
            let senderPublicKey = Data(hexString: event.pubkey)
        else {
            logger.error("DM \(event.id, privacy: .public) has invalid sender public key.")
            return
        }

        guard let parentKeyPair = try context.keyStore.fetchKeyPair(role: .parent) else {
            logger.warning("No parent key configured. Skipping DM \(event.id, privacy: .public).")
            return
        }

        let parentSigningKey = try Curve25519.Signing.PrivateKey(rawRepresentation: parentKeyPair.privateKeyData)

        let plaintext: Data
        do {
            plaintext = try context.cryptoService.decryptDirectMessage(
                ciphertext,
                recipientPrivateKey: parentSigningKey,
                senderPublicKey: senderPublicKey
            )
        } catch {
            logger.error("Failed to decrypt DM \(event.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let baseEnvelope: DMEnvelope
        do {
            baseEnvelope = try dmDecoder.decode(DMEnvelope.self, from: plaintext)
        } catch {
            logger.error("Failed to decode DM envelope for \(event.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let kind = DMKind(rawValue: baseEnvelope.t) else {
            logger.warning("Unsupported DM kind \(baseEnvelope.t, privacy: .public)")
            return
        }

        switch kind {
        case .familyLink:
            let payload = try dmDecoder.decode(FamilyLinkMessage.self, from: plaintext)
            try await reduceFamilyLinkDM(payload)
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
        case .like, .report:
            logger.info("Received \(kind.rawValue, privacy: .public) DM; handling deferred.")
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

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? dmEncoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func reduceFamilyLinkDM(_ message: FamilyLinkMessage) async throws {
        let pairKey = normalizedPairKey(message.pair)
        let updatedAt = Date(timeIntervalSince1970: message.ts)
        let metadataJSON = encodeJSON(message)

        try await performBackgroundTask { context in
            let request = FamilyLinkEntity.fetchRequest()
            request.predicate = NSPredicate(format: "pairIdentifier == %@", pairKey)
            request.fetchLimit = 1

            let entity = try context.fetch(request).first ?? {
                let newEntity = FamilyLinkEntity(context: context)
                newEntity.pairIdentifier = pairKey
                return newEntity
            }()

            entity.status = message.status
            entity.updatedAt = updatedAt
            entity.metadataJSON = metadataJSON

            try context.save()
        }
    }

    private func reduceFollowDM(_ message: FollowMessage) async throws {
        let updatedAt = Date(timeIntervalSince1970: message.ts)
        let metadataJSON = encodeJSON(message)

        try await performBackgroundTask { context in
            let request = FollowEntity.fetchRequest()
            request.predicate = NSPredicate(
                format: "followerChild == %@ AND targetChild == %@",
                message.followerChild,
                message.targetChild
            )
            request.fetchLimit = 1

            let entity = try context.fetch(request).first ?? {
                let newEntity = FollowEntity(context: context)
                newEntity.followerChild = message.followerChild
                newEntity.targetChild = message.targetChild
                return newEntity
            }()

            entity.status = message.status
            entity.approvedFrom = message.approvedFrom
            entity.approvedTo = message.approvedTo
            entity.updatedAt = updatedAt
            entity.metadataJSON = metadataJSON

            try context.save()
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

            let entity = try context.fetch(request).first ?? {
                let newEntity = RemoteVideoEntity(context: context)
                newEntity.videoId = message.videoId
                return newEntity
            }()

            entity.ownerChild = message.ownerChild
            entity.title = message.meta?.title ?? "Untitled"
            entity.duration = message.meta?.duration ?? 0
            entity.createdAt = createdAt
            entity.blobURL = message.blob.url
            entity.thumbURL = message.thumb.url
            entity.wrappedKeyJSON = cryptoJSON
            entity.visibility = message.policy?.visibility ?? "followers"
            entity.expiresAt = expiresAt
            entity.status = "available"
            entity.lastSyncedAt = lastSynced
            entity.metadataJSON = metadataJSON

            try context.save()
        }
    }

    private func reduceVideoRevokeDM(_ message: VideoLifecycleMessage) async throws {
        try await performBackgroundTask { context in
            let request = RemoteVideoEntity.fetchRequest()
            request.predicate = NSPredicate(format: "videoId == %@", message.videoId)
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                self.logger.warning("Received revoke for unknown video \(message.videoId)")
                return
            }

            entity.status = "revoked"
            entity.lastSyncedAt = Date(timeIntervalSince1970: message.ts)
            entity.metadataJSON = self.encodeJSON(message)

            try context.save()
        }
    }

    private func reduceVideoDeleteDM(_ message: VideoLifecycleMessage) async throws {
        try await performBackgroundTask { context in
            let request = RemoteVideoEntity.fetchRequest()
            request.predicate = NSPredicate(format: "videoId == %@", message.videoId)
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                self.logger.warning("Received delete for unknown video \(message.videoId)")
                return
            }

            entity.status = "deleted"
            entity.lastSyncedAt = Date(timeIntervalSince1970: message.ts)
            entity.metadataJSON = self.encodeJSON(message)

            try context.save()
        }
    }

    private func normalizedPairKey(_ pair: [String]) -> String {
        pair.sorted().joined(separator: "|")
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
