//
//  RemotePlaybackStore.swift
//  MyTube
//
//  Created by Assistant on 11/27/25.
//

import Combine
import CoreData
import Foundation
import OSLog

struct RemotePlaybackRecord: Identifiable, Sendable {
    struct Key: Hashable, Sendable {
        let videoId: String
        let profileId: UUID
    }

    let id: UUID
    let key: Key
    var playCount: Int
    var completionRate: Double
    var replayRate: Double
    var lastPlayedAt: Date?

    init(
        id: UUID = UUID(),
        videoId: String,
        profileId: UUID,
        playCount: Int = 0,
        completionRate: Double = 0,
        replayRate: Double = 0,
        lastPlayedAt: Date? = nil
    ) {
        self.id = id
        self.key = Key(videoId: videoId, profileId: profileId)
        self.playCount = playCount
        self.completionRate = completionRate
        self.replayRate = replayRate
        self.lastPlayedAt = lastPlayedAt
    }
}

@MainActor
final class RemotePlaybackStore: ObservableObject {
    @Published private(set) var records: [RemotePlaybackRecord.Key: RemotePlaybackRecord] = [:]

    private let persistence: PersistenceController
    private let logger = Logger(subsystem: "com.mytube", category: "RemotePlaybackStore")

    init(persistence: PersistenceController) {
        self.persistence = persistence
        Task {
            await loadRecords()
        }
    }

    func record(
        videoId: String,
        profileId: UUID,
        progress: Double,
        completed: Bool,
        at date: Date = Date()
    ) async -> RemotePlaybackRecord {
        let key = RemotePlaybackRecord.Key(videoId: videoId, profileId: profileId)
        var record = records[key] ?? RemotePlaybackRecord(videoId: videoId, profileId: profileId)

        if completed {
            record.playCount += 1
            record.completionRate = 1.0
            record.replayRate = min(1.0, record.replayRate + 0.1)
        } else {
            record.completionRate = max(record.completionRate, max(0.0, min(1.0, progress)))
        }
        record.lastPlayedAt = date

        records[key] = record
        await persist(record)
        return record
    }

    func metrics(for videoId: String, profileId: UUID) -> RemotePlaybackRecord? {
        records[RemotePlaybackRecord.Key(videoId: videoId, profileId: profileId)]
    }

    private func loadRecords() async {
        let context = persistence.container.viewContext
        let request = NSFetchRequest<RemotePlaybackEntity>(entityName: "RemotePlayback")

        do {
            let entities = try context.fetch(request)
            var loaded: [RemotePlaybackRecord.Key: RemotePlaybackRecord] = [:]

            for entity in entities {
                guard
                    let id = entity.id,
                    let videoId = entity.videoId,
                    let profileId = entity.profileId
                else { continue }
                let record = RemotePlaybackRecord(
                    id: id,
                    videoId: videoId,
                    profileId: profileId,
                    playCount: Int(entity.playCount),
                    completionRate: entity.completionRate,
                    replayRate: entity.replayRate,
                    lastPlayedAt: entity.lastPlayedAt
                )
                loaded[record.key] = record
            }

            records = loaded
            logger.info("Loaded \(loaded.count) remote playback records")
        } catch {
            logger.error("Failed to load remote playback records: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist(_ record: RemotePlaybackRecord) async {
        let context = persistence.container.newBackgroundContext()
        await context.perform {
            let request = NSFetchRequest<RemotePlaybackEntity>(entityName: "RemotePlayback")
            request.predicate = NSPredicate(
                format: "videoId == %@ AND profileId == %@",
                record.key.videoId,
                record.key.profileId as CVarArg
            )
            request.fetchLimit = 1

            do {
                let entity = try context.fetch(request).first ?? RemotePlaybackEntity(context: context)
                entity.id = record.id
                entity.videoId = record.key.videoId
                entity.profileId = record.key.profileId
                entity.playCount = Int16(clamping: record.playCount)
                entity.completionRate = record.completionRate
                entity.replayRate = record.replayRate
                entity.lastPlayedAt = record.lastPlayedAt
                try context.save()
            } catch {
                self.logger.error("Failed to persist remote playback record: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
