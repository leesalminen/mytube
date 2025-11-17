//
//  PersistenceController.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import CoreData
import Foundation

final class PersistenceController {
    static let shared = PersistenceController()

    private(set) var container: NSPersistentContainer
    private let isInMemory: Bool
    private let storeURLOverride: URL?

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    init(inMemory: Bool = false, storeURL: URL? = nil) {
        self.isInMemory = inMemory
        self.storeURLOverride = storeURL
        container = PersistenceController.buildContainer(inMemory: inMemory, storeURL: storeURL)
        configureContexts(on: container)
    }

    static func preview() -> PersistenceController {
        let controller = PersistenceController(inMemory: true)
        SampleDataSeeder(context: controller.viewContext).seed()
        return controller
    }

    func resetStores() throws {
        try destroyPersistentStores()
        container = PersistenceController.buildContainer(inMemory: isInMemory, storeURL: storeURLOverride)
        configureContexts(on: container)
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        context.transactionAuthor = "background"
        return context
    }

    func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask { context in
            context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
            context.transactionAuthor = "background"
            block(context)
        }
    }

    private func destroyPersistentStores() throws {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            guard let url = store.url else { continue }
            try coordinator.destroyPersistentStore(at: url, ofType: store.type, options: nil)
        }
    }

    private func configureContexts(on container: NSPersistentContainer) {
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        viewContext.transactionAuthor = "main"
    }

    private static func defaultStoreURL(fileManager: FileManager = .default) -> URL {
        let storeName = "MyTube.sqlite"
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        guard let appSupport else {
            return URL(fileURLWithPath: "/dev/null")
        }

        let myTubeDirectory = appSupport.appendingPathComponent("MyTube", isDirectory: true)
        if !fileManager.fileExists(atPath: myTubeDirectory.path) {
            try? fileManager.createDirectory(
                at: myTubeDirectory,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.protectionKey: FileProtectionType.complete]
            )
        }

        return myTubeDirectory.appendingPathComponent(storeName, isDirectory: false)
    }

    private static func buildContainer(inMemory: Bool, storeURL: URL?) -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "MyTube")

        let description: NSPersistentStoreDescription
        if let existingDescription = container.persistentStoreDescriptions.first {
            description = existingDescription
        } else {
            description = NSPersistentStoreDescription()
            container.persistentStoreDescriptions = [description]
        }

        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        } else if let storeURL {
            description.url = storeURL
        } else {
            description.url = defaultStoreURL()
        }

        description.shouldAddStoreAsynchronously = false
        description.setOption(
            FileProtectionType.complete as NSObject,
            forKey: NSPersistentStoreFileProtectionKey
        )
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Failed to load persistent stores: \(error)")
            }
        }

        return container
    }
}

/// Seeds a small set of data for previews and UI tests.
struct SampleDataSeeder {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func seed() {
        guard (try? context.count(for: ProfileEntity.fetchRequest())) == 0 else { return }

        let profile = ProfileEntity(context: context)
        profile.id = UUID()
        profile.name = "Sample Kid"
        profile.theme = ThemeDescriptor.ocean.rawValue
        profile.avatarAsset = "avatar.dolphin"
        profile.mlsGroupId = nil

        let video = VideoEntity(context: context)
        video.id = UUID()
        video.profileId = profile.id
        video.title = "Welcome to MyTube"
        video.filePath = "preview.welcome.mp4"
        video.thumbPath = "preview.welcome.jpg"
        video.createdAt = Date()
        video.duration = 30
        video.playCount = 0
        video.completionRate = 0.0
        video.replayRate = 0.0
        video.liked = false
        video.hidden = false
        video.tagsJSON = #"["welcome"]"#
        video.cvLabelsJSON = #"["smile"]"#
        video.faceCount = 1
        video.loudness = 0.2

        do {
            try context.save()
        } catch {
            context.rollback()
            assertionFailure("Failed to seed sample data: \(error)")
        }
    }
}
