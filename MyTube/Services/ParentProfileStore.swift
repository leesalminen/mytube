//
//  ParentProfileStore.swift
//  MyTube
//
//  Created by Codex on 12/10/25.
//

import CoreData
import Foundation
import OSLog

enum ParentProfileStoreError: Error {
    case entityMissing
}

final class ParentProfileStore: ObservableObject {
    private let persistence: PersistenceController
    private let logger = Logger(subsystem: "com.mytube", category: "ParentProfileStore")

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func profile(for publicKey: String) throws -> ParentProfileModel? {
        let request = ParentProfileEntity.fetchRequest()
        request.predicate = NSPredicate(format: "publicKey == %@", publicKey.lowercased())
        request.fetchLimit = 1
        guard let entity = try persistence.viewContext.fetch(request).first else {
            return nil
        }
        return ParentProfileModel(entity: entity)
    }

    func upsertProfile(
        publicKey: String,
        name: String?,
        displayName: String?,
        about: String?,
        pictureURLString: String?,
        wrapPublicKey: Data?,
        updatedAt: Date,
        in context: NSManagedObjectContext? = nil
    ) throws -> ParentProfileModel {
        let lowercasedKey = publicKey.lowercased()
        let targetContext: NSManagedObjectContext
        let isExternalContext: Bool

        if let context {
            targetContext = context
            isExternalContext = true
        } else {
            targetContext = persistence.newBackgroundContext()
            isExternalContext = false
        }

        var result: ParentProfileModel?
        var capturedError: Error?

        let work = {
            do {
                let request = ParentProfileEntity.fetchRequest()
                request.predicate = NSPredicate(format: "publicKey == %@", lowercasedKey)
                request.fetchLimit = 1

                let entity: ParentProfileEntity
                if let existing = try targetContext.fetch(request).first {
                    if let existingUpdatedAt = existing.updatedAt,
                       existingUpdatedAt >= updatedAt {
                        result = ParentProfileModel(entity: existing)
                        return
                    }
                    entity = existing
                } else {
                    entity = ParentProfileEntity(context: targetContext)
                    entity.publicKey = lowercasedKey
                }

                entity.name = name
                entity.displayName = displayName
                entity.about = about
                entity.pictureURL = pictureURLString
                entity.wrapPublicKey = wrapPublicKey
                entity.updatedAt = updatedAt

                if targetContext.hasChanges {
                    try targetContext.save()
                }
                result = ParentProfileModel(entity: entity)
            } catch {
                capturedError = error
                self.logger.error("Failed to upsert parent profile \(lowercasedKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if isExternalContext {
            work()
        } else {
            targetContext.performAndWait(work)
        }

        if let error = capturedError {
            throw error
        }

        guard let profile = result else {
            throw ParentProfileStoreError.entityMissing
        }
        return profile
    }
}
