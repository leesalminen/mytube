//
//  ReportCoordinator.swift
//  MyTube
//
//  Created by Assistant on 02/15/26.
//

import Foundation
import OSLog

actor ReportCoordinator {
    enum ReportCoordinatorError: Error {
        case parentIdentityMissing
        case subjectUnknown
    }

    private let reportStore: ReportStore
    private let remoteVideoStore: RemoteVideoStore
    private let marmotShareService: MarmotShareService
    private let keyStore: KeychainKeyStore
    private let storagePaths: StoragePaths
    private let relationshipStore: RelationshipStore
    private let groupMembershipCoordinator: any GroupMembershipCoordinating
    private let logger = Logger(subsystem: "com.mytube", category: "ReportCoordinator")

    init(
        reportStore: ReportStore,
        remoteVideoStore: RemoteVideoStore,
        marmotShareService: MarmotShareService,
        keyStore: KeychainKeyStore,
        storagePaths: StoragePaths,
        relationshipStore: RelationshipStore,
        groupMembershipCoordinator: any GroupMembershipCoordinating
    ) {
        self.reportStore = reportStore
        self.remoteVideoStore = remoteVideoStore
        self.marmotShareService = marmotShareService
        self.keyStore = keyStore
        self.storagePaths = storagePaths
        self.relationshipStore = relationshipStore
        self.groupMembershipCoordinator = groupMembershipCoordinator
    }

    @discardableResult
    func submitReport(
        videoId: String,
        subjectChild: String,
        reason: ReportReason,
        note: String?,
        action: ReportAction,
        createdAt: Date = Date()
    ) async throws -> ReportModel {
        guard let parentPair = try keyStore.fetchKeyPair(role: .parent) else {
            throw ReportCoordinatorError.parentIdentityMissing
        }

        let reporterKey = parentPair.publicKeyBech32 ?? parentPair.publicKeyHex
        let message = ReportMessage(
            videoId: videoId,
            subjectChild: subjectChild,
            reason: reason.rawValue,
            note: note,
            by: reporterKey,
            timestamp: createdAt
        )

        let stored = try await reportStore.ingestReportMessage(
            message,
            isOutbound: true,
            createdAt: createdAt,
            action: action
        )

        let targetGroups = resolveRecipientGroups(
            videoId: videoId,
            subjectChild: subjectChild
        )

        if targetGroups.isEmpty {
            logger.warning("No Marmot groups resolved for report on video \(videoId, privacy: .public)")
        }

        for groupId in targetGroups {
            do {
                try await marmotShareService.publishReport(
                    message: message,
                    mlsGroupId: groupId
                )
            } catch {
                logger.error("Failed to publish report for \(videoId, privacy: .public) to group \(groupId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            _ = try remoteVideoStore.markVideoAsBlocked(
                videoId: videoId,
                reason: reason.rawValue,
                storagePaths: storagePaths,
                timestamp: createdAt
            )
        } catch {
            logger.error("Failed to mark remote video \(videoId, privacy: .public) as blocked: \(error.localizedDescription, privacy: .public)")
        }

        let finalAction: ReportAction = action == .none ? .reportOnly : action
        do {
            try await reportStore.updateStatus(
                reportId: stored.id,
                status: .actioned,
                action: finalAction,
                lastActionAt: createdAt
            )
        } catch {
            logger.error("Failed to update report status after submission: \(error.localizedDescription, privacy: .public)")
        }

        await applyRelationshipAction(
            action: finalAction,
            subjectChild: subjectChild,
            timestamp: createdAt
        )

        return stored
    }

    // MARK: - Moderation recipients

    private func resolveRecipientGroups(
        videoId: String,
        subjectChild: String
    ) -> [String] {
        var candidateKeys: Set<String> = []
        if let normalized = canonicalChildKey(subjectChild) {
            candidateKeys.insert(normalized)
        }

        if candidateKeys.isEmpty,
           let remote = try? remoteVideoStore.fetchVideo(videoId: videoId),
           let normalized = canonicalChildKey(remote.ownerChild) {
            candidateKeys.insert(normalized)
        }

        guard !candidateKeys.isEmpty else {
            return []
        }

        let relationships: [FollowModel]
        do {
            relationships = try relationshipStore.fetchFollowRelationships()
        } catch {
            logger.error("Failed to load follow relationships for report recipients: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var groupIds: Set<String> = []
        for follow in relationships {
            guard let groupId = follow.mlsGroupId, !groupId.isEmpty else { continue }
            let followerHex = follow.followerChildHex()?.lowercased()
            let targetHex = follow.targetChildHex()?.lowercased()
            if followerHex.map(candidateKeys.contains) == true || targetHex.map(candidateKeys.contains) == true {
                groupIds.insert(groupId)
            }
        }

        return Array(groupIds)
    }

    private func applyRelationshipAction(
        action: ReportAction,
        subjectChild: String,
        timestamp: Date
    ) async {
        guard action == .unfollow || action == .block else { return }
        guard let parentPair = try? keyStore.fetchKeyPair(role: .parent) else {
            logger.info("Skipping follow action; parent identity missing.")
            return
        }

        let localParentHex = parentPair.publicKeyHex.lowercased()
        let normalizedSubject = ParentIdentityKey(string: subjectChild)?.hex.lowercased() ?? subjectChild.lowercased()
        let actorKey = parentPair.publicKeyBech32 ?? parentPair.publicKeyHex

        let relationships: [FollowModel]
        do {
            relationships = try await MainActor.run {
                try self.relationshipStore.fetchFollowRelationships()
            }
        } catch {
            logger.error("Failed loading follow relationships for report action: \(error.localizedDescription, privacy: .public)")
            return
        }

        for follow in relationships {
            let followerHex = follow.followerChildHex()?.lowercased()
            let targetHex = follow.targetChildHex()?.lowercased()
            guard followerHex == normalizedSubject || targetHex == normalizedSubject else { continue }
            guard let remoteParentKey = resolveRemoteParentKey(for: follow, localParentHex: localParentHex) else { continue }
            guard let remoteParentIdentity = ParentIdentityKey(string: remoteParentKey) else { continue }
            guard let groupId = follow.mlsGroupId else {
                logger.warning("Skipping removal for follow \(follow.id, privacy: .public); missing group identifier.")
                continue
            }

            do {
                try await removeParentFromGroup(
                    follow: follow,
                    groupId: groupId,
                    remoteParent: remoteParentIdentity,
                    newStatus: action == .block ? .blocked : .revoked,
                    actorKey: actorKey,
                    timestamp: timestamp
                )
            } catch {
                logger.error("Failed applying \(action.rawValue, privacy: .public) to follow \(follow.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func removeParentFromGroup(
        follow: FollowModel,
        groupId: String,
        remoteParent: ParentIdentityKey,
        newStatus: FollowModel.Status,
        actorKey: String,
        timestamp: Date
    ) async throws {
        let request = GroupMembershipCoordinator.RemoveMembersRequest(
            mlsGroupId: groupId,
            memberPublicKeys: [remoteParent.hex.lowercased()],
            relayOverride: nil
        )
        _ = try await groupMembershipCoordinator.removeMembers(request: request)

        let message = FollowMessage(
            followerChild: follow.followerChild,
            targetChild: follow.targetChild,
            approvedFrom: false,
            approvedTo: false,
            status: newStatus.rawValue,
            by: actorKey,
            timestamp: timestamp
        )

        do {
            _ = try relationshipStore.upsertFollow(
                message: message,
                updatedAt: timestamp,
                participantKeys: [remoteParent.displayValue],
                mlsGroupId: groupId
            )
        } catch {
            logger.error("Failed to update relationship for follow \(follow.id, privacy: .public) after removal: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveRemoteParentKey(
        for follow: FollowModel,
        localParentHex: String
    ) -> String? {
        var remoteParents = follow.remoteParentKeys(localParentHex: localParentHex)
        if remoteParents.isEmpty,
           let fallback = follow.lastMessage?.by,
           let normalized = ParentIdentityKey(string: fallback)?.hex.lowercased(),
           normalized.caseInsensitiveCompare(localParentHex) != .orderedSame {
            remoteParents = [normalized]
        }

        guard let remoteHex = remoteParents.first else {
            return nil
        }
        return ParentIdentityKey(string: remoteHex)?.displayValue ?? remoteHex
    }

    private func canonicalChildKey(_ value: String) -> String? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ParentIdentityKey(string: value)?.hex.lowercased()
    }
}
