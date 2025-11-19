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
    private let groupMembershipCoordinator: any GroupMembershipCoordinating
    private let logger = Logger(subsystem: "com.mytube", category: "ReportCoordinator")

    init(
        reportStore: ReportStore,
        remoteVideoStore: RemoteVideoStore,
        marmotShareService: MarmotShareService,
        keyStore: KeychainKeyStore,
        storagePaths: StoragePaths,
        groupMembershipCoordinator: any GroupMembershipCoordinating
    ) {
        self.reportStore = reportStore
        self.remoteVideoStore = remoteVideoStore
        self.marmotShareService = marmotShareService
        self.keyStore = keyStore
        self.storagePaths = storagePaths
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

        // Follow relationships removed - get groups from remote video store
        // For now, return empty (reports will need to be sent to all groups)
        return []
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

        // Follow relationships removed - actions would be applied via MDK removeMembers
        // For now, just log - reports filed but don't auto-change group membership
        logger.info("Relationship action \(action.rawValue) for \(subjectChild) - would remove from groups")
    }

    private func canonicalChildKey(_ value: String) -> String? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ParentIdentityKey(string: value)?.hex.lowercased()
    }
}
