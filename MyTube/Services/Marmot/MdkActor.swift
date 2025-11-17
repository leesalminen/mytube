//
//  MdkActor.swift
//  MyTube
//
//  Created by Codex on 02/14/26.
//

import Foundation
import OSLog
@preconcurrency import MDKBindings

protocol MarmotMdkClient: Actor {
    func createGroup(
        creatorPublicKey: String,
        memberKeyPackageEventsJson: [String],
        name: String,
        description: String,
        relays: [String],
        admins: [String]
    ) throws -> CreateGroupResult
    func addMembers(mlsGroupId: String, keyPackageEventsJson: [String]) throws -> AddMembersResult
    func removeMembers(mlsGroupId: String, memberPublicKeys: [String]) throws -> GroupUpdateResult
    func parseKeyPackage(eventJson: String) throws
    func processWelcome(wrapperEventId: String, rumorEventJson: String) throws -> Welcome
    func getRelays(inGroup mlsGroupId: String) throws -> [String]
    func mergePendingCommit(mlsGroupId: String) throws
    func processMessage(eventJson: String) throws -> ProcessMessageResult
}

protocol MarmotMessageProducing: Actor {
    func createMessage(
        mlsGroupId: String,
        senderPublicKey: String,
        content: String,
        kind: UInt16
    ) throws -> String
}

protocol MarmotMessageQuerying: Actor {
    func getGroups() throws -> [Group]
    func getMessages(inGroup mlsGroupId: String) throws -> [Message]
}

protocol WelcomeHandling: Actor {
    func getPendingWelcomes() throws -> [Welcome]
    func acceptWelcome(welcomeJson: String) throws
    func declineWelcome(welcomeJson: String) throws
}

/// Thin async wrapper around the MDK (Marmot) bindings.
/// The underlying UniFFI surface is synchronous and not thread-safe, so we funnel all usage through this actor.
actor MdkActor {
    struct Stats: Sendable {
        let groupCount: Int
        let pendingWelcomeCount: Int
    }

    private let logger = Logger(subsystem: "com.mytube", category: "MdkActor")
    private let databaseURL: URL
    private let mdk: Mdk

    init(storagePaths: StoragePaths, fileManager: FileManager = .default) throws {
        try self.init(databaseURL: storagePaths.mdkDatabaseURL(), fileManager: fileManager)
    }

    init(databaseURL: URL, fileManager: FileManager = .default) throws {
        self.databaseURL = databaseURL
        let parentDirectory = databaseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)
        }
#if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: parentDirectory.path)
#endif
        mdk = try newMdk(dbPath: databaseURL.path)
        logger.debug("Initialized MDK database at \(databaseURL.path, privacy: .public)")
    }

    // MARK: - Diagnostics

    func stats() -> Stats {
        let groupCount = (try? mdk.getGroups().count) ?? 0
        let pendingWelcomeCount = (try? mdk.getPendingWelcomes().count) ?? 0
        return Stats(groupCount: groupCount, pendingWelcomeCount: pendingWelcomeCount)
    }

    func databasePath() -> URL {
        databaseURL
    }

    // MARK: - Group management

    func createGroup(
        creatorPublicKey: String,
        memberKeyPackageEventsJson: [String],
        name: String,
        description: String,
        relays: [String],
        admins: [String]
    ) throws -> CreateGroupResult {
        try mdk.createGroup(
            creatorPublicKey: creatorPublicKey,
            memberKeyPackageEventsJson: memberKeyPackageEventsJson,
            name: name,
            description: description,
            relays: relays,
            admins: admins
        )
    }

    func addMembers(mlsGroupId: String, keyPackageEventsJson: [String]) throws -> AddMembersResult {
        try mdk.addMembers(mlsGroupId: mlsGroupId, keyPackageEventsJson: keyPackageEventsJson)
    }

    func removeMembers(mlsGroupId: String, memberPublicKeys: [String]) throws -> GroupUpdateResult {
        try mdk.removeMembers(mlsGroupId: mlsGroupId, memberPublicKeys: memberPublicKeys)
    }

    func getGroup(mlsGroupId: String) throws -> Group? {
        try mdk.getGroup(mlsGroupId: mlsGroupId)
    }

    func getGroups() throws -> [Group] {
        try mdk.getGroups()
    }

    func getMembers(inGroup mlsGroupId: String) throws -> [String] {
        try mdk.getMembers(mlsGroupId: mlsGroupId)
    }

    func getRelays(inGroup mlsGroupId: String) throws -> [String] {
        try mdk.getRelays(mlsGroupId: mlsGroupId)
    }

    func mergePendingCommit(mlsGroupId: String) throws {
        try mdk.mergePendingCommit(mlsGroupId: mlsGroupId)
    }

    func processMessage(eventJson: String) throws -> ProcessMessageResult {
        try mdk.processMessage(eventJson: eventJson)
    }

    // MARK: - Key packages & welcomes

    func createKeyPackage(forPublicKey publicKey: String, relays: [String]) throws -> KeyPackageResult {
        try mdk.createKeyPackageForEvent(publicKey: publicKey, relays: relays)
    }

    func parseKeyPackage(eventJson: String) throws {
        try mdk.parseKeyPackage(eventJson: eventJson)
    }

    func processWelcome(wrapperEventId: String, rumorEventJson: String) throws -> Welcome {
        try mdk.processWelcome(wrapperEventId: wrapperEventId, rumorEventJson: rumorEventJson)
    }

    func acceptWelcome(welcomeJson: String) throws {
        try mdk.acceptWelcome(welcomeJson: welcomeJson)
    }

    func declineWelcome(welcomeJson: String) throws {
        try mdk.declineWelcome(welcomeJson: welcomeJson)
    }

    func getPendingWelcomes() throws -> [Welcome] {
        try mdk.getPendingWelcomes()
    }

    // MARK: - Messaging

    func createMessage(
        mlsGroupId: String,
        senderPublicKey: String,
        content: String,
        kind: UInt16
    ) throws -> String {
        try mdk.createMessage(
            mlsGroupId: mlsGroupId,
            senderPublicKey: senderPublicKey,
            content: content,
            kind: kind
        )
    }

    func getMessages(inGroup mlsGroupId: String) throws -> [Message] {
        try mdk.getMessages(mlsGroupId: mlsGroupId)
    }

    func getMessage(eventId: String) throws -> Message? {
        try mdk.getMessage(eventId: eventId)
    }
}

extension MdkActor: MarmotMdkClient {}
extension MdkActor: MarmotMessageProducing {}
extension MdkActor: MarmotMessageQuerying {}
extension MdkActor: WelcomeHandling {}
