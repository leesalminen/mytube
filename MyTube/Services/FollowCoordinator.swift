//
//  FollowCoordinator.swift
//  MyTube
//
//  Created by Codex on 11/15/25.
//

import Foundation
import OSLog
import NostrSDK

enum FollowCoordinatorError: Error {
    case parentIdentityMissing
    case childIdentityMissing
    case invalidChildKey
    case invalidParentKey
    case remoteParentKeyMissing
    case relationshipNotFound
    case invalidChildRole
}

actor FollowCoordinator {
    private let publishTimeoutNanoseconds: UInt64 = 10 * NSEC_PER_SEC
    private let identityManager: IdentityManager
    private let relationshipStore: RelationshipStore
    private let directMessageOutbox: DirectMessageOutbox
    private let nostrClient: NostrClient
    private let relayDirectory: RelayDirectory
    private let signer: NostrEventSigner
    private let logger = Logger(subsystem: "com.mytube", category: "FollowCoordinator")
    private let encoder: JSONEncoder

    init(
        identityManager: IdentityManager,
        relationshipStore: RelationshipStore,
        directMessageOutbox: DirectMessageOutbox,
        nostrClient: NostrClient,
        relayDirectory: RelayDirectory,
        signer: NostrEventSigner = NostrEventSigner()
    ) {
        self.identityManager = identityManager
        self.relationshipStore = relationshipStore
        self.directMessageOutbox = directMessageOutbox
        self.nostrClient = nostrClient
        self.relayDirectory = relayDirectory
        self.signer = signer

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
    }

    @discardableResult
    func requestFollow(
        followerProfile: ProfileModel,
        targetChildKey: String,
        targetParentKey: String,
        now: Date = Date()
    ) async throws -> FollowModel {
        guard let parentIdentity = try identityManager.parentIdentity() else {
            throw FollowCoordinatorError.parentIdentityMissing
        }

        let childIdentity = try identityManager.ensureChildIdentity(for: followerProfile)
        let localParent = try normalizeParentKey(parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex)
        let followerChildKey = try normalizePublicKey(
            childIdentity.publicKeyBech32 ?? (try NIP19.encodePublicKey(childIdentity.keyPair.publicKeyData))
        )
        let targetChild = try normalizePublicKey(targetChildKey)
        let targetParent = try normalizeParentKey(targetParentKey)

        let byKey = parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex
        let followerHex = followerChildKey.hex
        let targetHex = targetChild.hex
        let message = FollowMessage(
            followerChild: followerHex,
            targetChild: targetHex,
            approvedFrom: true,
            approvedTo: false,
            status: FollowModel.Status.pending.rawValue,
            by: byKey,
            timestamp: now
        )

        try await directMessageOutbox.sendMessage(
            message,
            kind: .follow,
            recipientPublicKey: targetParentKey,
            additionalTags: [NostrTagBuilder.make(name: "d", value: followPointerIdentifier(follower: followerHex, target: targetHex))],
            createdAt: now
        )

        try await publishFollowPointer(
            message: message,
            followerHex: followerHex,
            targetHex: targetHex,
            signerPair: parentIdentity.keyPair,
            createdAt: now
        )

        return try relationshipStore.upsertFollow(
            message: message,
            updatedAt: now,
            participantKeys: [targetParent.displayValue]
        )
    }

    @discardableResult
    func approveFollow(
        follow: FollowModel,
        approvingProfile: ProfileModel,
        now: Date = Date()
    ) async throws -> FollowModel {
        guard let parentIdentity = try identityManager.parentIdentity() else {
            throw FollowCoordinatorError.parentIdentityMissing
        }

        guard let childIdentity = try identityManager.childIdentity(for: approvingProfile) else {
            throw FollowCoordinatorError.childIdentityMissing
        }

        let localChild = try normalizePublicKey(
            childIdentity.publicKeyBech32 ?? (try NIP19.encodePublicKey(childIdentity.keyPair.publicKeyData))
        )
        let followerChild = try normalizePublicKey(follow.followerChild)
        let targetChild = try normalizePublicKey(follow.targetChild)
        let localParent = try normalizeParentKey(parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex)

        // Determine whether the approving profile is the target child (being followed).
        guard localChild.hex.caseInsensitiveCompare(targetChild.hex) == .orderedSame else {
            throw FollowCoordinatorError.invalidChildRole
        }

        let remoteParentSource = follow.lastMessage?.by ??
            follow.remoteParentKeys(localParentHex: localParent.hex).first

        guard let remoteParentKey = remoteParentSource else {
            throw FollowCoordinatorError.remoteParentKeyMissing
        }

        let remoteParent = try normalizeParentKey(remoteParentKey)
        let remoteParentDisplay = remoteParent.bech32 ?? remoteParent.hex

        let approvedFrom = follow.approvedFrom
        let newApprovedTo = true
        let status: FollowModel.Status = approvedFrom && newApprovedTo ? .active : .pending
        let byKey = parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex

        let followerHex = followerChild.hex
        let targetHex = targetChild.hex
        let message = FollowMessage(
            followerChild: followerHex,
            targetChild: targetHex,
            approvedFrom: approvedFrom,
            approvedTo: newApprovedTo,
            status: status.rawValue,
            by: byKey,
            timestamp: now
        )

        try await directMessageOutbox.sendMessage(
            message,
            kind: .follow,
            recipientPublicKey: remoteParentDisplay,
            additionalTags: [NostrTagBuilder.make(name: "d", value: followPointerIdentifier(follower: followerHex, target: targetHex))],
            createdAt: now
        )

        try await publishFollowPointer(
            message: message,
            followerHex: followerHex,
            targetHex: targetHex,
            signerPair: parentIdentity.keyPair,
            createdAt: now
        )

        return try relationshipStore.upsertFollow(
            message: message,
            updatedAt: now,
            participantKeys: [remoteParent.displayValue]
        )
    }

    @discardableResult
    func revokeFollow(
        follow: FollowModel,
        remoteParentKey: String,
        now: Date = Date()
    ) async throws -> FollowModel {
        guard let parentIdentity = try identityManager.parentIdentity() else {
            throw FollowCoordinatorError.parentIdentityMissing
        }

        let followerChild = try normalizePublicKey(follow.followerChild)
        let targetChild = try normalizePublicKey(follow.targetChild)
        let remoteParent = try normalizeParentKey(remoteParentKey)

        let followerHex = followerChild.hex
        let targetHex = targetChild.hex

        let message = FollowMessage(
            followerChild: followerHex,
            targetChild: targetHex,
            approvedFrom: false,
            approvedTo: false,
            status: FollowModel.Status.revoked.rawValue,
            by: parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex,
            timestamp: now
        )

        try await directMessageOutbox.sendMessage(
            message,
            kind: .follow,
            recipientPublicKey: remoteParentKey,
            additionalTags: [NostrTagBuilder.make(name: "d", value: followPointerIdentifier(follower: followerHex, target: targetHex))],
            createdAt: now
        )

        try await publishFollowPointer(
            message: message,
            followerHex: followerHex,
            targetHex: targetHex,
            signerPair: parentIdentity.keyPair,
            createdAt: now
        )

        return try relationshipStore.upsertFollow(
            message: message,
            updatedAt: now,
            participantKeys: [remoteParent.displayValue]
        )
    }

    // MARK: - Helpers

    private func publishFollowPointer(
        message: FollowMessage,
        followerHex: String,
        targetHex: String,
        signerPair: NostrKeyPair,
        createdAt: Date
    ) async throws {
        let contentData = try encoder.encode(message)
        guard let content = String(data: contentData, encoding: .utf8) else {
            logger.error("Failed to encode follow pointer content.")
            return
        }

        let tags: [Tag] = [
            NostrTagBuilder.make(name: "d", value: followPointerIdentifier(follower: followerHex, target: targetHex)),
            NostrTagBuilder.make(name: "type", value: DirectMessageKind.follow.rawValue),
            NostrTagBuilder.make(name: "p", value: targetHex)
        ]

        let event = try signer.makeEvent(
            kind: .mytubeChildFollowPointer,
            tags: tags,
            content: content,
            keyPair: signerPair,
            createdAt: createdAt
        )

        let relays = await relayDirectory.currentRelayURLs()
        guard !relays.isEmpty else {
            logger.warning("Skipping follow pointer publish; no relays configured.")
            return
        }

        let connectedRelaySet = Set(
            (await nostrClient.relayStatuses())
                .filter { $0.status == .connected }
                .map(\.url)
        )
        let targetRelays = relays.filter { connectedRelaySet.contains($0) }
        guard !targetRelays.isEmpty else {
            logger.warning("No connected relays available; skipping follow pointer publish.")
            throw DirectMessageOutboxError.relaysUnavailable
        }

        do {
            try await publish(event: event, to: targetRelays)
            logger.info("Published follow pointer \(event.idHex, privacy: .public)")
        } catch let error as DirectMessageOutboxError {
            throw error
        } catch {
            logger.error("Failed to publish follow pointer: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func followPointerIdentifier(follower: String, target: String) -> String {
        "mytube/follow:\(follower):\(target)"
    }

    private func normalizePublicKey(_ input: String) throws -> NormalizedKey {
        guard let key = NormalizedKey(publicKey: input) else {
            throw FollowCoordinatorError.invalidChildKey
        }
        return key
    }

    private func normalizeParentKey(_ input: String) throws -> NormalizedKey {
        guard let key = NormalizedKey(publicKey: input) else {
            throw FollowCoordinatorError.invalidParentKey
        }
        return key
    }

    private func publish(event: NostrEvent, to relays: [URL]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.nostrClient.publish(event: event, to: relays)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: self.publishTimeoutNanoseconds)
                throw DirectMessageOutboxError.sendTimedOut
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

extension FollowCoordinatorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .parentIdentityMissing:
            return "Parent identity is missing. Complete parent onboarding first."
        case .childIdentityMissing:
            return "Child key is missing for this profile."
        case .invalidChildKey:
            return "Child key format is invalid."
        case .invalidParentKey:
            return "Parent key format is invalid."
        case .remoteParentKeyMissing:
            return "The remote parent key could not be determined."
        case .relationshipNotFound:
            return "Relationship record was not found."
        case .invalidChildRole:
            return "Only the target child's parent can approve this follow."
        }
    }
}

private struct NormalizedKey {
    let data: Data
    let hex: String
    let bech32: String?
    var displayValue: String { bech32 ?? hex }

    init?(publicKey input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = Data(hexString: trimmed), data.count == 32 {
            self.data = data
            self.hex = data.hexEncodedString()
            self.bech32 = try? NIP19.encodePublicKey(data)
            return
        }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix(NIP19Kind.npub.rawValue) {
            guard let decoded = try? NIP19.decode(lowered), decoded.kind == .npub else {
                return nil
            }
            self.data = decoded.data
            self.hex = decoded.data.hexEncodedString()
            self.bech32 = try? NIP19.encodePublicKey(decoded.data)
            return
        }

        return nil
    }
}
