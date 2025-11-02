//
//  LikePublisher.swift
//  MyTube
//
//  Created by Assistant on 11/2/25.
//

import Foundation
import OSLog
import NostrSDK

enum LikePublisherError: Error {
    case missingChildProfile
    case missingVideoOwner
    case rateLimitExceeded
}

/// Publishes like events to Nostr
actor LikePublisher {
    private let directMessageOutbox: any DirectMessageSending
    private let keyStore: KeychainKeyStore
    private let childProfileStore: ChildProfileStore
    private let remoteVideoStore: RemoteVideoStore
    private let logger = Logger(subsystem: "com.mytube", category: "LikePublisher")
    
    // Rate limiting: 120 likes per hour per child
    private var rateLimitTracker: [String: [Date]] = [:]
    private let maxLikesPerHour = 120
    
    init(
        directMessageOutbox: any DirectMessageSending,
        keyStore: KeychainKeyStore,
        childProfileStore: ChildProfileStore,
        remoteVideoStore: RemoteVideoStore
    ) {
        self.directMessageOutbox = directMessageOutbox
        self.keyStore = keyStore
        self.childProfileStore = childProfileStore
        self.remoteVideoStore = remoteVideoStore
    }
    
    /// Publish a like for a video
    func publishLike(
        videoId: UUID,
        viewerChildNpub: String
    ) async throws {
        // Check rate limit
        try await checkRateLimit(for: viewerChildNpub)
        
        // Get video owner information
        let ownerInfo = try await getVideoOwnerInfo(videoId: videoId)
        
        // Get parent key
        let parentKeyPair = try keyStore.ensureParentKeyPair()
        
        // Create like message
        let message = LikeMessage(
            videoId: videoId.uuidString,
            viewerChild: viewerChildNpub,
            by: parentKeyPair.publicKeyHex,
            timestamp: Date()
        )
        
        // Send to owner child device
        try await directMessageOutbox.sendMessage(
            message,
            kind: .like,
            recipientPublicKey: ownerInfo.ownerChildNpub,
            additionalTags: [
                NostrTagBuilder.make(name: "d", value: videoId.uuidString)
            ],
            relayOverride: nil,
            createdAt: Date()
        )
        
        // Also send to owner's parents
        for parentNpub in ownerInfo.ownerParentNpubs {
            do {
                try await directMessageOutbox.sendMessage(
                    message,
                    kind: .like,
                    recipientPublicKey: parentNpub,
                    additionalTags: [
                        NostrTagBuilder.make(name: "d", value: videoId.uuidString)
                    ],
                    relayOverride: nil,
                    createdAt: Date()
                )
            } catch {
                // Log but don't fail if parent notification fails
                logger.warning("Failed to notify parent \(parentNpub.prefix(8))… about like: \(error)")
            }
        }
        
        // Track for rate limiting
        await recordLikeForRateLimit(childNpub: viewerChildNpub)
        
        logger.info("Published like for video \(videoId) from \(viewerChildNpub.prefix(8))…")
    }
    
    /// Publish an unlike (like removal) - this could be a separate message type in the future
    func publishUnlike(
        videoId: UUID,
        viewerChildNpub: String
    ) async throws {
        // For MVP, we don't send unlike messages to Nostr
        // The like is just removed locally
        logger.info("Unlike recorded locally for video \(videoId) from \(viewerChildNpub.prefix(8))…")
    }
    
    private func getVideoOwnerInfo(videoId: UUID) async throws -> (ownerChildNpub: String, ownerParentNpubs: [String]) {
        do {
            if let remoteVideo = try remoteVideoStore.fetchVideo(videoId: videoId.uuidString) {
                let parentNpubs = try await getParentNpubs(for: remoteVideo.ownerChild)
                return (remoteVideo.ownerChild, parentNpubs)
            }
        } catch {
            logger.error("Failed to load remote video \(videoId) for like publishing: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // If not found in remote videos, it might be a local video
        // For local videos, we would need to look up the owner from the video share messages
        // For now, throw an error as likes are primarily for shared videos
        throw LikePublisherError.missingVideoOwner
    }
    
    private func getParentNpubs(for childNpub: String) async throws -> [String] {
        // In a real implementation, this would look up the parent-child relationships
        // For now, return empty array as we don't have parent tracking yet
        return []
    }
    
    private func checkRateLimit(for childNpub: String) async throws {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        
        // Get existing likes in the past hour
        var recentLikes = rateLimitTracker[childNpub] ?? []
        
        // Remove likes older than one hour
        recentLikes = recentLikes.filter { $0 > oneHourAgo }
        
        // Check if limit exceeded
        if recentLikes.count >= maxLikesPerHour {
            logger.warning("Rate limit exceeded for child \(childNpub.prefix(8))…")
            throw LikePublisherError.rateLimitExceeded
        }
        
        // Update tracker
        rateLimitTracker[childNpub] = recentLikes
    }
    
    private func recordLikeForRateLimit(childNpub: String) async {
        var recentLikes = rateLimitTracker[childNpub] ?? []
        recentLikes.append(Date())
        rateLimitTracker[childNpub] = recentLikes
    }
}

extension LikePublisherError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingChildProfile:
            return "Child profile not found"
        case .missingVideoOwner:
            return "Video owner information not found"
        case .rateLimitExceeded:
            return "Too many likes. Please try again later."
        }
    }
}
