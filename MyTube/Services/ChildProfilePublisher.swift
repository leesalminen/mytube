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
        // Children no longer publish their own metadata
        // Child profiles are just local data owned by the parent
        // For now, just store locally without publishing to Nostr
        
        let baseName = nameOverride ?? profile.name
        
        // Use profile ID as a stable identifier instead of child pubkey
        let profileIdentifier = profile.id.uuidString.lowercased()
        
        return try childProfileStore.upsertProfile(
            publicKey: profileIdentifier,
            name: baseName,
            displayName: baseName,
            about: about,
            pictureURLString: pictureURL,
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
