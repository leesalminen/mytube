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
    private let videoLibrary: VideoLibrary
    private let directMessageOutbox: DirectMessageOutbox
    private let keyStore: KeychainKeyStore
    private let backendClient: BackendClient
    private let safetyStore: SafetyConfigurationStore
    private let storagePaths: StoragePaths
    private let relationshipStore: RelationshipStore
    private let followCoordinator: FollowCoordinator
    private let logger = Logger(subsystem: "com.mytube", category: "ReportCoordinator")
    private let moderatorCacheDuration: TimeInterval = 60 * 60
    private let jsonDecoder = JSONDecoder()

    private var cachedModeratorKey: String?
    private var moderatorKeyExpiresAt: Date?
    private var moderatorFetchTask: Task<String?, Never>?

    init(
        reportStore: ReportStore,
        remoteVideoStore: RemoteVideoStore,
        videoLibrary: VideoLibrary,
        directMessageOutbox: DirectMessageOutbox,
        keyStore: KeychainKeyStore,
        backendClient: BackendClient,
        safetyStore: SafetyConfigurationStore,
        storagePaths: StoragePaths,
        relationshipStore: RelationshipStore,
        followCoordinator: FollowCoordinator
    ) {
        self.reportStore = reportStore
        self.remoteVideoStore = remoteVideoStore
        self.videoLibrary = videoLibrary
        self.directMessageOutbox = directMessageOutbox
        self.keyStore = keyStore
        self.backendClient = backendClient
        self.safetyStore = safetyStore
        self.storagePaths = storagePaths
        self.relationshipStore = relationshipStore
        self.followCoordinator = followCoordinator
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

        let stored = try await MainActor.run {
            try await self.reportStore.ingestReportMessage(
                message,
                isOutbound: true,
                createdAt: createdAt,
                action: action
            )
        }

        let recipients = await resolveRecipients(
            for: videoId,
            subjectChild: subjectChild,
            reporterKey: reporterKey
        )

        if recipients.isEmpty {
            logger.warning("No recipients resolved for report on video \(videoId, privacy: .public)")
        }

        for recipient in recipients {
            do {
                try await directMessageOutbox.sendMessage(
                    message,
                    kind: .report,
                    recipientPublicKey: recipient,
                    additionalTags: [
                        NostrTagBuilder.make(name: "d", value: videoId)
                    ],
                    createdAt: createdAt
                )
            } catch {
                logger.error("Failed to deliver report for \(videoId, privacy: .public) to \(recipient.prefix(12), privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            try await MainActor.run {
                try await self.reportStore.updateStatus(
                    reportId: stored.id,
                    status: .actioned,
                    action: finalAction,
                    lastActionAt: createdAt
                )
            }
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

    private func resolveRecipients(
        for videoId: String,
        subjectChild: String,
        reporterKey: String
    ) async -> [String] {
        var recipients: Set<String> = []

        // Always notify the subject child's device/parents.
        if !subjectChild.isEmpty {
            recipients.insert(subjectChild)
        }

        if let remote = try? remoteVideoStore.fetchVideo(videoId: videoId) {
            if let message = decodeVideoShareMessage(remote.metadataJSON) {
                recipients.insert(message.by)
                recipients.insert(message.ownerChild)
            }
        }

        if let moderator = await fetchModeratorKey(forceRefresh: false) {
            recipients.insert(moderator)
        }

        // Do not send the DM back to the reporter.
        recipients.remove(reporterKey)
        if let normalizedReporter = ParentIdentityKey(string: reporterKey) {
            let reporterHex = normalizedReporter.hex.lowercased()
            let reporterDisplay = normalizedReporter.displayValue.lowercased()
            recipients = Set(
                recipients.filter {
                    let lowered = $0.lowercased()
                    return lowered != reporterHex && lowered != reporterDisplay
                }
            )
        }

        return Array(recipients)
    }

    private func decodeVideoShareMessage(_ json: String) -> VideoShareMessage? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(VideoShareMessage.self, from: data)
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

            do {
                switch action {
                case .unfollow:
                    _ = try await followCoordinator.revokeFollow(
                        follow: follow,
                        remoteParentKey: remoteParentKey,
                        now: timestamp
                    )
                case .block:
                    _ = try await followCoordinator.blockFollow(
                        follow: follow,
                        remoteParentKey: remoteParentKey,
                        now: timestamp
                    )
                default:
                    break
                }
            } catch {
                logger.error("Failed applying \(action.rawValue, privacy: .public) to follow \(follow.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
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

    private func fetchModeratorKey(forceRefresh: Bool) async -> String? {
        if !forceRefresh,
           let cachedModeratorKey,
           let expiresAt = moderatorKeyExpiresAt,
           expiresAt.timeIntervalSinceNow > 0 {
            return cachedModeratorKey
        }

        if !forceRefresh,
           let stored = safetyStore.moderatorPublicKey(),
           let fetchedAt = safetyStore.moderatorKeyFetchedAt(),
           Date().timeIntervalSince(fetchedAt) < moderatorCacheDuration {
            cachedModeratorKey = stored
            moderatorKeyExpiresAt = fetchedAt.addingTimeInterval(moderatorCacheDuration)
            return stored
        }

        if let moderatorFetchTask {
            return await moderatorFetchTask.value
        }

        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            do {
                let response = try await self.backendClient.fetchModeratorKey()
                self.cachedModeratorKey = response
                self.moderatorKeyExpiresAt = Date().addingTimeInterval(self.moderatorCacheDuration)
                self.safetyStore.saveModeratorPublicKey(response)
                return response
            } catch {
                self.logger.error("Failed to fetch moderator key: \(error.localizedDescription, privacy: .public)")
                return self.safetyStore.moderatorPublicKey()
            }
        }
        moderatorFetchTask = task
        let key = await task.value
        moderatorFetchTask = nil
        return key
    }
}
