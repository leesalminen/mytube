//
//  MarmotShareService.swift
//  MyTube
//
//  Created by Assistant on 03/01/26.
//

import Foundation
import NostrSDK
import OSLog

protocol MarmotMessagePublishing: AnyObject {
    func publishMessage(
        mlsGroupId: String,
        eventJson: String,
        relayOverride: [URL]?
    ) async throws -> NostrEvent
}

extension MarmotTransport: MarmotMessagePublishing {}

actor MarmotShareService {
    struct PublishResult {
        let groupId: String
        let event: NostrEvent
    }

    enum ShareError: Error {
        case parentIdentityMissing
        case payloadEncodingFailed
    }

    private let mdkActor: any MarmotMessageProducing
    private let transport: MarmotMessagePublishing
    private let keyStore: KeychainKeyStore
    private let logger = Logger(subsystem: "com.mytube", category: "MarmotShareService")
    private let encoder: JSONEncoder

    init(
        mdkActor: any MarmotMessageProducing,
        transport: MarmotMessagePublishing,
        keyStore: KeychainKeyStore
    ) {
        self.mdkActor = mdkActor
        self.transport = transport
        self.keyStore = keyStore

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
    }

    @discardableResult
    func publishVideoShare(
        message: VideoShareMessage,
        mlsGroupId: String,
        relayOverride: [URL]? = nil
    ) async throws -> PublishResult {
        let result = try await publish(
            message,
            mlsGroupId: mlsGroupId,
            kind: .videoShare,
            relayOverride: relayOverride
        )
        logger.debug("Published Marmot video share \(result.event.idHex, privacy: .public) to group \(mlsGroupId, privacy: .public)")
        return result
    }

    @discardableResult
    func publishVideoRevoke(
        message: VideoLifecycleMessage,
        mlsGroupId: String,
        relayOverride: [URL]? = nil
    ) async throws -> PublishResult {
        let result = try await publish(
            message,
            mlsGroupId: mlsGroupId,
            kind: .videoRevoke,
            relayOverride: relayOverride
        )
        logger.debug("Published Marmot video revoke \(result.event.idHex, privacy: .public) for video \(message.videoId, privacy: .public)")
        return result
    }

    @discardableResult
    func publishVideoDelete(
        message: VideoLifecycleMessage,
        mlsGroupId: String,
        relayOverride: [URL]? = nil
    ) async throws -> PublishResult {
        let result = try await publish(
            message,
            mlsGroupId: mlsGroupId,
            kind: .videoDelete,
            relayOverride: relayOverride
        )
        logger.debug("Published Marmot video delete \(result.event.idHex, privacy: .public) for video \(message.videoId, privacy: .public)")
        return result
    }

    @discardableResult
    func publishLike(
        message: LikeMessage,
        mlsGroupId: String,
        relayOverride: [URL]? = nil
    ) async throws -> PublishResult {
        let result = try await publish(
            message,
            mlsGroupId: mlsGroupId,
            kind: .like,
            relayOverride: relayOverride
        )
        logger.debug("Published Marmot like \(result.event.idHex, privacy: .public) for video \(message.videoId, privacy: .public)")
        return result
    }

    @discardableResult
    func publishReport(
        message: ReportMessage,
        mlsGroupId: String,
        relayOverride: [URL]? = nil
    ) async throws -> PublishResult {
        let result = try await publish(
            message,
            mlsGroupId: mlsGroupId,
            kind: .report,
            relayOverride: relayOverride
        )
        logger.debug("Published Marmot report \(result.event.idHex, privacy: .public) for video \(message.videoId, privacy: .public)")
        return result
    }

    private func publish<Message: Encodable>(
        _ message: Message,
        mlsGroupId: String,
        kind: MarmotMessageKind,
        relayOverride: [URL]? = nil
    ) async throws -> PublishResult {
        let senderPublicKey = try resolveParentPublicKey()
        let content = try encodePayload(message)
        let event = try await publishMessage(
            groupId: mlsGroupId,
            senderPublicKey: senderPublicKey,
            content: content,
            kind: kind,
            relayOverride: relayOverride
        )
        return PublishResult(groupId: mlsGroupId, event: event)
    }

    private func resolveParentPublicKey() throws -> String {
        guard let pair = try keyStore.fetchKeyPair(role: .parent) else {
            throw ShareError.parentIdentityMissing
        }
        return pair.publicKeyHex
    }

    private func encodePayload<Message: Encodable>(_ message: Message) throws -> String {
        do {
            let data = try encoder.encode(message)
            if let content = String(data: data, encoding: .utf8) {
                return content
            }
            throw ShareError.payloadEncodingFailed
        } catch let error as ShareError {
            throw error
        } catch {
            logger.error("Failed to encode Marmot payload: \(error.localizedDescription, privacy: .public)")
            throw ShareError.payloadEncodingFailed
        }
    }

    private func publishMessage(
        groupId: String,
        senderPublicKey: String,
        content: String,
        kind: MarmotMessageKind,
        relayOverride: [URL]?
    ) async throws -> NostrEvent {
        let eventJson = try await mdkActor.createMessage(
            mlsGroupId: groupId,
            senderPublicKey: senderPublicKey,
            content: content,
            kind: kind.rawValue
        )
        return try await transport.publishMessage(
            mlsGroupId: groupId,
            eventJson: eventJson,
            relayOverride: relayOverride
        )
    }
}

extension MarmotShareService.ShareError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .parentIdentityMissing:
            return "Parent identity is missing. Generate or import it before sharing."
        case .payloadEncodingFailed:
            return "Unable to encode the Marmot message payload."
        }
    }
}
