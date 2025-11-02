//
//  LikeStore.swift
//  MyTube
//
//  Created by Assistant on 11/2/25.
//

import Foundation
import CoreData
import OSLog

/// A like record representing a like action on a video
struct LikeRecord: Identifiable, Sendable {
    let id: UUID
    let videoId: UUID
    let viewerChildNpub: String
    let viewerChildName: String?
    let timestamp: Date
    let isLocalUser: Bool

    /// Human-readable label for UI surfaces.
    var displayName: String {
        if isLocalUser {
            return "You"
        }
        if let viewerChildName, !viewerChildName.isEmpty {
            return viewerChildName
        }
        let trimmed = viewerChildNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        if trimmed.count <= 12 {
            return trimmed
        }
        let prefix = trimmed.prefix(8)
        let suffix = trimmed.suffix(4)
        return "\(prefix)…\(suffix)"
    }
    
    init(
        id: UUID = UUID(),
        videoId: UUID,
        viewerChildNpub: String,
        viewerChildName: String? = nil,
        timestamp: Date = Date(),
        isLocalUser: Bool = false
    ) {
        self.id = id
        self.videoId = videoId
        self.viewerChildNpub = viewerChildNpub
        self.viewerChildName = viewerChildName
        self.timestamp = timestamp
        self.isLocalUser = isLocalUser
    }
}

/// Manages storage and retrieval of video likes
@MainActor
class LikeStore: ObservableObject {
    @Published private(set) var likesByVideo: [UUID: Set<String>] = [:]
    @Published private(set) var likeRecords: [UUID: [LikeRecord]] = [:]
    
    private let persistenceController: PersistenceController
    private let logger = Logger(subsystem: "com.mytube", category: "LikeStore")
    private let childProfileStore: ChildProfileStore
    
    init(
        persistenceController: PersistenceController,
        childProfileStore: ChildProfileStore
    ) {
        self.persistenceController = persistenceController
        self.childProfileStore = childProfileStore
        Task {
            await loadLikes()
        }
    }
    
    /// Check if the current user has liked a video
    func hasLiked(videoId: UUID, viewerChildNpub: String) -> Bool {
        let key = normalizeKey(viewerChildNpub)
        return likesByVideo[videoId]?.contains(key) ?? false
    }
    
    /// Get the total like count for a video
    func likeCount(for videoId: UUID) -> Int {
        likesByVideo[videoId]?.count ?? 0
    }
    
    /// Get all like records for a video
    func likes(for videoId: UUID) -> [LikeRecord] {
        likeRecords[videoId] ?? []
    }
    
    /// Record a like from a user
    func recordLike(
        videoId: UUID,
        viewerChildNpub: String,
        viewerDisplayName: String? = nil,
        timestamp: Date = Date(),
        isLocalUser: Bool = false
    ) async {
        let canonicalKey = normalizeKey(viewerChildNpub)
        let childName: String?
        if let viewerDisplayName, !viewerDisplayName.isEmpty {
            childName = viewerDisplayName
        } else {
            childName = await fetchChildName(for: canonicalKey)
        }
        
        let record = LikeRecord(
            videoId: videoId,
            viewerChildNpub: canonicalKey,
            viewerChildName: childName,
            timestamp: timestamp,
            isLocalUser: isLocalUser
        )
        
        // Update in-memory state
        var videoLikes = likesByVideo[videoId] ?? Set<String>()
        videoLikes.insert(canonicalKey)
        likesByVideo[videoId] = videoLikes
        
        var videoRecords = likeRecords[videoId] ?? []
        // Remove any existing like from this user to avoid duplicates
        videoRecords.removeAll { $0.viewerChildNpub == canonicalKey }
        videoRecords.append(record)
        videoRecords.sort { $0.timestamp > $1.timestamp }
        likeRecords[videoId] = videoRecords
        
        // Persist to Core Data
        await saveLike(record)
        
        logger.info("Recorded like for video \(videoId) from \(canonicalKey)")
    }
    
    /// Remove a like from a user
    func removeLike(videoId: UUID, viewerChildNpub: String) async {
        let canonicalKey = normalizeKey(viewerChildNpub)
        // Update in-memory state
        likesByVideo[videoId]?.remove(canonicalKey)
        if likesByVideo[videoId]?.isEmpty == true {
            likesByVideo[videoId] = nil
        }
        
        likeRecords[videoId]?.removeAll { $0.viewerChildNpub == canonicalKey }
        if likeRecords[videoId]?.isEmpty == true {
            likeRecords[videoId] = nil
        }
        
        // Remove from Core Data
        await deleteLike(videoId: videoId, viewerChildNpub: canonicalKey)
        
        logger.info("Removed like for video \(videoId) from \(canonicalKey)")
    }
    
    /// Process an incoming like message from Nostr
    func processIncomingLike(_ message: LikeMessage) async {
        guard let videoId = UUID(uuidString: message.videoId) else {
            logger.error("Invalid video ID in like message: \(message.videoId)")
            return
        }
        
        await recordLike(
            videoId: videoId,
            viewerChildNpub: message.viewerChild,
            timestamp: Date(timeIntervalSince1970: message.ts),
            isLocalUser: false
        )
    }
    
    private func normalizeKey(_ value: String) -> String {
        if let canonical = childProfileStore.canonicalKey(value) {
            return canonical
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    private func fetchChildName(for key: String) async -> String? {
        do {
            if let profile = try childProfileStore.profile(for: key) {
                return profile.bestName
            }
        } catch {
            logger.error("Failed to fetch child name for \(key): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return nil
    }
    
    private func loadLikes() async {
        let context = persistenceController.container.viewContext
        let request = NSFetchRequest<LikeEntity>(entityName: "LikeEntity")
        
        do {
            let entities = try context.fetch(request)
            var didNormalize = false
            
            for entity in entities {
                guard
                    let videoId = entity.videoId,
                    let storedKey = entity.viewerChildNpub,
                    let timestamp = entity.timestamp
                else { continue }
                
                let canonicalKey = normalizeKey(storedKey)
                if canonicalKey != storedKey {
                    entity.viewerChildNpub = canonicalKey
                    didNormalize = true
                }
                
                let record = LikeRecord(
                    videoId: videoId,
                    viewerChildNpub: canonicalKey,
                    viewerChildName: entity.viewerChildName,
                    timestamp: timestamp,
                    isLocalUser: entity.isLocalUser
                )
                
                // Update lookup structures
                var videoLikes = likesByVideo[videoId] ?? Set<String>()
                videoLikes.insert(canonicalKey)
                likesByVideo[videoId] = videoLikes
                
                var videoRecords = likeRecords[videoId] ?? []
                videoRecords.append(record)
                videoRecords.sort { $0.timestamp > $1.timestamp }
                likeRecords[videoId] = videoRecords
            }
            
            if didNormalize, context.hasChanges {
                try context.save()
            }
            
            logger.info("Loaded \(entities.count) likes from storage")
        } catch {
            logger.error("Failed to load likes: \(error)")
        }
    }
    
    private func saveLike(_ record: LikeRecord) async {
        let context = persistenceController.container.newBackgroundContext()
        
        await context.perform {
            // Check if like already exists
            let request = NSFetchRequest<LikeEntity>(entityName: "LikeEntity")
            let canonicalKey = self.normalizeKey(record.viewerChildNpub)
            request.predicate = NSPredicate(
                format: "videoId == %@ AND viewerChildNpub == %@",
                record.videoId as CVarArg,
                canonicalKey
            )
            
            do {
                let existing = try context.fetch(request).first
                let entity = existing ?? LikeEntity(context: context)
                
                entity.id = record.id
                entity.videoId = record.videoId
                entity.viewerChildNpub = canonicalKey
                entity.viewerChildName = record.viewerChildName
                entity.timestamp = record.timestamp
                entity.isLocalUser = record.isLocalUser
                
                try context.save()
            } catch {
                self.logger.error("Failed to save like: \(error)")
            }
        }
    }
    
    private func deleteLike(videoId: UUID, viewerChildNpub: String) async {
        let context = persistenceController.container.newBackgroundContext()
        
        await context.perform {
            let request = NSFetchRequest<LikeEntity>(entityName: "LikeEntity")
            let canonicalKey = self.normalizeKey(viewerChildNpub)
            request.predicate = NSPredicate(
                format: "videoId == %@ AND viewerChildNpub == %@",
                videoId as CVarArg,
                canonicalKey
            )
            
            do {
                let entities = try context.fetch(request)
                for entity in entities {
                    context.delete(entity)
                }
                try context.save()
            } catch {
                self.logger.error("Failed to delete like: \(error)")
            }
        }
    }
}
