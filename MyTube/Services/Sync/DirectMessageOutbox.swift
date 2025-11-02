//
//  DirectMessageOutbox.swift
//  MyTube
//
//  Created by Codex on 10/26/25.
//

import Foundation
import OSLog
import NostrSDK

enum DirectMessageOutboxError: Error {
    case missingParentKey
    case invalidRecipientKey
    case noRelaysConfigured
    case relaysUnavailable
    case encodingFailed
    case sendTimedOut
}

protocol DirectMessageSending: Sendable {
    @discardableResult
    func sendMessage<Payload: Encodable>(
        _ message: Payload,
        kind: DirectMessageKind,
        recipientPublicKey: String,
        additionalTags: [Tag],
        relayOverride: [URL]?,
        createdAt: Date
    ) async throws -> NostrEvent
}

actor DirectMessageOutbox {
    private let sendTimeoutNanoseconds: UInt64 = 10 * NSEC_PER_SEC
    private let keyStore: KeychainKeyStore
    private let cryptoService: CryptoEnvelopeService
    private let nostrClient: NostrClient
    private let relayDirectory: RelayDirectory
    private let signer: NostrEventSigner
    private let logger = Logger(subsystem: "com.mytube", category: "DMOutbox")
    private let encoder: JSONEncoder

    init(
        keyStore: KeychainKeyStore,
        cryptoService: CryptoEnvelopeService,
        nostrClient: NostrClient,
        relayDirectory: RelayDirectory,
        signer: NostrEventSigner = NostrEventSigner()
    ) {
        self.keyStore = keyStore
        self.cryptoService = cryptoService
        self.nostrClient = nostrClient
        self.relayDirectory = relayDirectory
        self.signer = signer

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
    }

    @discardableResult
    func sendMessage<Payload: Encodable>(
        _ message: Payload,
        kind: DirectMessageKind,
        recipientPublicKey: String,
        additionalTags: [Tag] = [],
        relayOverride: [URL]? = nil,
        createdAt: Date = Date()
    ) async throws -> NostrEvent {
        let payloadData: Data
        do {
            payloadData = try encoder.encode(message)
        } catch {
            logger.error("DM payload encoding failed: \(error.localizedDescription, privacy: .public)")
            throw DirectMessageOutboxError.encodingFailed
        }

        return try await sendEncodedMessage(
            payloadData,
            kind: kind,
            recipientPublicKey: recipientPublicKey,
            additionalTags: additionalTags,
            relayOverride: relayOverride,
            createdAt: createdAt
        )
    }

    @discardableResult
    func sendEncodedMessage(
        _ payloadData: Data,
        kind: DirectMessageKind,
        recipientPublicKey: String,
        additionalTags: [Tag] = [],
        relayOverride: [URL]? = nil,
        createdAt: Date = Date()
    ) async throws -> NostrEvent {
        let recipient = try resolveRecipientKey(recipientPublicKey)

        let parentPair: NostrKeyPair
        if let existing = try keyStore.fetchKeyPair(role: .parent) {
            parentPair = existing
        } else {
            parentPair = try keyStore.ensureParentKeyPair()
        }

        let ciphertext = try cryptoService.encryptDirectMessage(
            payloadData,
            senderPrivateKeyData: parentPair.privateKeyData,
            recipientPublicKeyXOnly: recipient.data
        )

        var tags: [Tag] = [
            NostrTagBuilder.make(name: "p", value: recipient.hex),
            NostrTagBuilder.make(name: "type", value: kind.rawValue)
        ]
        tags.append(contentsOf: additionalTags)

        let relays: [URL]
        if let override = relayOverride {
            relays = override
        } else {
            relays = await relayDirectory.currentRelayURLs()
        }
        guard !relays.isEmpty else {
            throw DirectMessageOutboxError.noRelaysConfigured
        }

        let connectedRelaySet = Set(
            (await nostrClient.relayStatuses())
                .filter { $0.status == .connected }
                .map(\.url)
        )
        let targetRelays = relays.filter { connectedRelaySet.contains($0) }
        guard !targetRelays.isEmpty else {
            logger.warning("No connected relays available; skipping DM send to \(recipient.hex.prefix(8), privacy: .public)…")
            throw DirectMessageOutboxError.relaysUnavailable
        }

        let event = try signer.makeEvent(
            kind: .directMessage,
            tags: tags,
            content: ciphertext,
            keyPair: parentPair,
            createdAt: createdAt
        )

        do {
            try await publish(event: event, to: targetRelays)
            logger.info("Published DM \(event.idHex, privacy: .public) to \(recipient.hex.prefix(8))…")
        } catch let error as DirectMessageOutboxError {
            throw error
        } catch let error as NostrClientError {
            logger.error("Failed to publish DM \(event.idHex, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw DirectMessageOutboxError.relaysUnavailable
        } catch {
            logger.error("Failed to publish DM \(event.idHex, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        return event
    }

    private func resolveRecipientKey(_ input: String) throws -> (hex: String, data: Data) {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw DirectMessageOutboxError.invalidRecipientKey
        }

        let lowercase = cleaned.lowercased()
        if let hexData = Data(hexString: lowercase), hexData.count == 32 {
            return (hexData.hexEncodedString(), hexData)
        }

        if lowercase.hasPrefix(NIP19Kind.npub.rawValue) {
            let decoded = try NIP19.decode(lowercase)
            guard decoded.kind == .npub else {
                throw DirectMessageOutboxError.invalidRecipientKey
            }
            return (decoded.data.hexEncodedString(), decoded.data)
        }

        throw DirectMessageOutboxError.invalidRecipientKey
    }

    private func publish(event: NostrEvent, to relays: [URL]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.nostrClient.publish(event: event, to: relays)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: self.sendTimeoutNanoseconds)
                throw DirectMessageOutboxError.sendTimedOut
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

extension DirectMessageOutbox: DirectMessageSending {}

extension DirectMessageOutboxError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingParentKey:
            return "Parent key is missing. Complete the parent onboarding flow first."
        case .invalidRecipientKey:
            return "Recipient key must be a 64-character hex string or start with npub."
        case .noRelaysConfigured:
            return "No relays are configured. Add and enable at least one relay."
        case .relaysUnavailable:
            return "Relays are not connected yet. Wait for a connection and try again."
        case .encodingFailed:
            return "Failed to encode the direct message payload."
        case .sendTimedOut:
            return "Relays did not confirm the message. Check your connection and try again."
        }
    }
}
