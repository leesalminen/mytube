//
//  ChildProfilePublisher.swift
//  MyTube
//
//  Created by Codex on 12/24/25.
//

import Foundation
import OSLog
import NostrSDK

enum ChildProfilePublisherError: Error {
    case childIdentityMissing
    case relaysUnavailable
    case encodingFailed
}

actor ChildProfilePublisher {
    private let identityManager: IdentityManager
    private let childProfileStore: ChildProfileStore
    private let nostrClient: NostrClient
    private let relayDirectory: RelayDirectory
    private let signer: NostrEventSigner
    private let logger = Logger(subsystem: "com.mytube", category: "ChildProfilePublisher")
    private let encoder: JSONEncoder
    private let publishTimeoutNanoseconds: UInt64 = 10 * NSEC_PER_SEC

    init(
        identityManager: IdentityManager,
        childProfileStore: ChildProfileStore,
        nostrClient: NostrClient,
        relayDirectory: RelayDirectory,
        signer: NostrEventSigner = NostrEventSigner()
    ) {
        self.identityManager = identityManager
        self.childProfileStore = childProfileStore
        self.nostrClient = nostrClient
        self.relayDirectory = relayDirectory
        self.signer = signer

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    @discardableResult
    func publishProfile(
        for profile: ProfileModel,
        identity: ChildIdentity? = nil,
        nameOverride: String? = nil,
        displayNameOverride: String? = nil,
        about: String? = nil,
        pictureURL: String? = nil,
        createdAt: Date = Date()
    ) async throws -> ChildProfileModel {
        let resolvedIdentity: ChildIdentity
        if let identity {
            resolvedIdentity = identity
        } else if let existing = try identityManager.childIdentity(for: profile) {
            resolvedIdentity = existing
        } else {
            throw ChildProfilePublisherError.childIdentityMissing
        }

        var payload = ProfileMetadataPayload()
        let baseName = nameOverride ?? profile.name
        payload.name = baseName
        payload.displayName = displayNameOverride ?? baseName
        payload.about = about
        payload.picture = pictureURL

        let contentData: Data
        do {
            contentData = try encoder.encode(payload)
        } catch {
            throw ChildProfilePublisherError.encodingFailed
        }
        guard let content = String(data: contentData, encoding: .utf8) else {
            throw ChildProfilePublisherError.encodingFailed
        }

        let event = try signer.makeEvent(
            kind: .metadata,
            tags: [],
            content: content,
            keyPair: resolvedIdentity.keyPair,
            createdAt: createdAt
        )

        let relays = await relayDirectory.currentRelayURLs()
        guard !relays.isEmpty else {
            throw ChildProfilePublisherError.relaysUnavailable
        }

        let connectedRelaySet = Set(
            (await nostrClient.relayStatuses())
                .filter { $0.status == .connected }
                .map(\.url)
        )
        let targetRelays = relays.filter { connectedRelaySet.contains($0) }
        guard !targetRelays.isEmpty else {
            throw ChildProfilePublisherError.relaysUnavailable
        }

        try await publish(event: event, to: targetRelays)
        logger.info("Published child metadata event \(event.idHex, privacy: .public)")

        return try childProfileStore.upsertProfile(
            publicKey: resolvedIdentity.publicKeyHex.lowercased(),
            name: payload.name,
            displayName: payload.displayName,
            about: payload.about,
            pictureURLString: payload.picture,
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
                throw ChildProfilePublisherError.relaysUnavailable
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
