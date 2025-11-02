//
//  ParentProfilePublisher.swift
//  MyTube
//
//  Created by Codex on 12/10/25.
//

import Foundation
import OSLog
import NostrSDK

enum ParentProfilePublisherError: Error {
    case parentIdentityMissing
    case relaysUnavailable
    case encodingFailed
}

actor ParentProfilePublisher {
    private let identityManager: IdentityManager
    private let parentProfileStore: ParentProfileStore
    private let nostrClient: NostrClient
    private let relayDirectory: RelayDirectory
    private let signer: NostrEventSigner
    private let logger = Logger(subsystem: "com.mytube", category: "ParentProfilePublisher")
    private let encoder: JSONEncoder
    private let publishTimeoutNanoseconds: UInt64 = 10 * NSEC_PER_SEC

    init(
        identityManager: IdentityManager,
        parentProfileStore: ParentProfileStore,
        nostrClient: NostrClient,
        relayDirectory: RelayDirectory,
        signer: NostrEventSigner = NostrEventSigner()
    ) {
        self.identityManager = identityManager
        self.parentProfileStore = parentProfileStore
        self.nostrClient = nostrClient
        self.relayDirectory = relayDirectory
        self.signer = signer

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    @discardableResult
    func publishProfile(
        name: String?,
        displayName: String?,
        about: String?,
        pictureURL: String?,
        nip05: String? = nil,
        createdAt: Date = Date()
    ) async throws -> ParentProfileModel {
        guard let parentIdentity = try identityManager.parentIdentity() else {
            throw ParentProfilePublisherError.parentIdentityMissing
        }

        let wrapKeyPair = try identityManager.parentWrapKeyPair()
        let wrapKeyBase64 = try wrapKeyPair.publicKeyBase64()

        var payload = ProfileMetadataPayload()
        payload.name = name
        payload.displayName = displayName
        payload.about = about
        payload.picture = pictureURL
        payload.nip05 = nip05
        payload.wrapKey = wrapKeyBase64

        let contentData: Data
        do {
            contentData = try encoder.encode(payload)
        } catch {
            throw ParentProfilePublisherError.encodingFailed
        }
        guard let content = String(data: contentData, encoding: .utf8) else {
            throw ParentProfilePublisherError.encodingFailed
        }

        let event = try signer.makeEvent(
            kind: .metadata,
            tags: [],
            content: content,
            keyPair: parentIdentity.keyPair,
            createdAt: createdAt
        )

        let relays = await relayDirectory.currentRelayURLs()
        guard !relays.isEmpty else {
            throw ParentProfilePublisherError.relaysUnavailable
        }

        let connectedRelaySet = Set(
            (await nostrClient.relayStatuses())
                .filter { $0.status == .connected }
                .map(\.url)
        )
        let targetRelays = relays.filter { connectedRelaySet.contains($0) }
        guard !targetRelays.isEmpty else {
            throw ParentProfilePublisherError.relaysUnavailable
        }

        try await publish(event: event, to: targetRelays)
        logger.info("Published parent metadata event \(event.idHex, privacy: .public)")

        let wrapKeyData = try wrapKeyPair.publicKeyData()
        return try parentProfileStore.upsertProfile(
            publicKey: parentIdentity.publicKeyHex.lowercased(),
            name: name,
            displayName: displayName,
            about: about,
            pictureURLString: pictureURL,
            wrapPublicKey: wrapKeyData,
            updatedAt: createdAt
        )
    }

    private func publish(event: NostrEvent, to relays: [URL]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.nostrClient.publish(event: event, to: relays)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: self.publishTimeoutNanoseconds)
                throw ParentProfilePublisherError.relaysUnavailable
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
