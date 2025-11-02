//
//  ReportStore.swift
//  MyTube
//
//  Created by Assistant on 02/15/26.
//

import CoreData
import Foundation
import OSLog

@MainActor
final class ReportStore: ObservableObject {
    @Published private(set) var reports: [ReportModel] = []

    private let persistence: PersistenceController
    private let logger = Logger(subsystem: "com.mytube", category: "ReportStore")

    init(persistence: PersistenceController) {
        self.persistence = persistence
        Task {
            await loadReports()
        }
    }

    func refresh() async {
        await loadReports()
    }

    func allReports() -> [ReportModel] {
        reports
    }

    func outboundReports() -> [ReportModel] {
        reports.filter { $0.isOutbound }.sorted { $0.createdAt > $1.createdAt }
    }

    func inboundReports() -> [ReportModel] {
        reports.filter { !$0.isOutbound }.sorted { $0.createdAt > $1.createdAt }
    }

    func ingestReportMessage(
        _ message: ReportMessage,
        isOutbound: Bool,
        createdAt: Date,
        deliveredAt: Date? = nil,
        defaultStatus: ReportStatus = .pending,
        action: ReportAction? = nil
    ) async throws -> ReportModel {
        try await performBackground { context in
            let request = ReportEntity.fetchRequest()
            request.predicate = NSPredicate(
                format: "videoId == %@ AND reporterKey == %@ AND subjectChild == %@",
                message.videoId,
                message.by,
                message.subjectChild
            )
            request.fetchLimit = 1

            let entity = try context.fetch(request).first ?? ReportEntity(context: context)
            if entity.id == nil {
                entity.id = UUID()
            }

            entity.videoId = message.videoId
            entity.subjectChild = message.subjectChild
            entity.reporterKey = message.by
            entity.reason = message.reason
            entity.note = message.note
            entity.createdAt = Date(timeIntervalSince1970: message.ts)
            entity.status = entity.status ?? defaultStatus.rawValue
            if let action {
                entity.actionTaken = action.rawValue
            } else if entity.actionTaken == nil {
                entity.actionTaken = ReportAction.none.rawValue
            }
            entity.isOutbound = isOutbound
            if let deliveredAt {
                entity.deliveredAt = deliveredAt
            }

            try context.save()
            guard let model = ReportModel(entity: entity) else {
                throw PersistenceError.entityDecodeFailed
            }
            await MainActor.run {
                self.upsertInMemory(model)
            }
            return model
        }
    }

    func updateStatus(
        reportId: UUID,
        status: ReportStatus,
        action: ReportAction? = nil,
        lastActionAt: Date = Date()
    ) async throws {
        try await performBackground { context in
            let request = ReportEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", reportId as CVarArg)
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                throw PersistenceError.entityMissing
            }

            entity.status = status.rawValue
            entity.lastActionAt = lastActionAt
            if let action {
                entity.actionTaken = action.rawValue
            }

            try context.save()
            guard let model = ReportModel(entity: entity) else {
                throw PersistenceError.entityDecodeFailed
            }
            await MainActor.run {
                self.upsertInMemory(model)
            }
        }
    }

    func markDelivered(reportId: UUID, deliveredAt: Date = Date()) async throws {
        try await performBackground { context in
            let request = ReportEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", reportId as CVarArg)
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                throw PersistenceError.entityMissing
            }

            entity.deliveredAt = deliveredAt
            if entity.status == ReportStatus.pending.rawValue {
                entity.status = ReportStatus.acknowledged.rawValue
            }

            try context.save()

            guard let model = ReportModel(entity: entity) else {
                throw PersistenceError.entityDecodeFailed
            }
            await MainActor.run {
                self.upsertInMemory(model)
            }
        }
    }

    func deleteAllReports() async throws {
        try await performBackground { context in
            let request = ReportEntity.fetchRequest()
            let entities = try context.fetch(request)
            for entity in entities {
                context.delete(entity)
            }
            try context.save()
            await MainActor.run {
                self.reports = []
            }
        }
    }

    // MARK: - Private

    private func loadReports() async {
        let viewContext = persistence.viewContext
        let request = ReportEntity.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \ReportEntity.createdAt, ascending: false)
        ]

        do {
            let entities = try viewContext.fetch(request)
            let models = entities.compactMap(ReportModel.init)
            reports = models
        } catch {
            logger.error("Failed to load reports: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func upsertInMemory(_ model: ReportModel) {
        var existing = reports
        if let index = existing.firstIndex(where: { $0.id == model.id }) {
            existing[index] = model
        } else {
            existing.append(model)
        }
        reports = existing.sorted { $0.createdAt > $1.createdAt }
    }

    private func performBackground<T>(
        _ block: @escaping (NSManagedObjectContext) async throws -> T
    ) async throws -> T {
        let context = persistence.newBackgroundContext()
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                Task {
                    do {
                        let result = try await block(context)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

private enum PersistenceError: Error {
    case entityMissing
    case entityDecodeFailed
}
