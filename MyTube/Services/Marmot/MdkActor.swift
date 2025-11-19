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
    func getMembers(inGroup mlsGroupId: String) throws -> [String]
    func getMessages(inGroup mlsGroupId: String) throws -> [Message]
}

protocol WelcomeHandling: Actor {
    func getPendingWelcomes() throws -> [Welcome]
    func acceptWelcome(welcome: Welcome) throws
    func declineWelcome(welcome: Welcome) throws
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
    private let fileManager: FileManager

    init(storagePaths: StoragePaths, fileManager: FileManager = .default) throws {
        try self.init(databaseURL: storagePaths.mdkDatabaseURL(), fileManager: fileManager)
    }

    init(databaseURL: URL, fileManager: FileManager = .default) throws {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
        let parentDirectory = databaseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)
        }
#if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: parentDirectory.path)
#endif
        do {
            mdk = try newMdk(dbPath: databaseURL.path)
            logger.debug("Initialized MDK database at \(databaseURL.path, privacy: .public)")
        } catch {
            logger.error("MDK init failed, attempting reset: \(error.localizedDescription, privacy: .public)")
            MdkActor.removeStoreFiles(at: databaseURL, fileManager: fileManager)
            mdk = try newMdk(dbPath: databaseURL.path)
            logger.debug("Recreated MDK database after reset at \(databaseURL.path, privacy: .public)")
        }
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
    
    private static func removeStoreFiles(at url: URL, fileManager: FileManager) {
        let basePath = url.deletingPathExtension().path
        let paths = [
            url.path,
            "\(basePath)-wal",
            "\(basePath)-shm"
        ]
        for path in paths {
            try? fileManager.removeItem(atPath: path)
        }
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
        logger.debug("🏗️ MdkActor.createGroup:")
        logger.debug("   Creator: \(creatorPublicKey.prefix(16))...")
        logger.debug("   Members: \(memberKeyPackageEventsJson.count) key packages")
        logger.debug("   Name: \(name)")
        logger.debug("   Relays: \(relays.count)")
        logger.debug("   Admins: \(admins.count)")
        
        do {
            let result = try mdk.createGroup(
                creatorPublicKey: creatorPublicKey,
                memberKeyPackageEventsJson: memberKeyPackageEventsJson,
                name: name,
                description: description,
                relays: relays,
                admins: admins
            )
            logger.debug("✅ MDK createGroup succeeded, group ID: \(result.group.mlsGroupId.prefix(16))...")
            logger.debug("   Welcome rumors: \(result.welcomeRumorsJson.count)")
            return result
        } catch {
            logger.error("❌ MDK createGroup failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func addMembers(mlsGroupId: String, keyPackageEventsJson: [String]) throws -> AddMembersResult {
        logger.debug("📦 MdkActor.addMembers:")
        logger.debug("   Group: \(mlsGroupId.prefix(16))...")
        logger.debug("   Key packages: \(keyPackageEventsJson.count)")
        for (i, json) in keyPackageEventsJson.enumerated() {
            logger.debug("   Package [\(i)] length: \(json.count)")
        }
        
        do {
            let result = try mdk.addMembers(mlsGroupId: mlsGroupId, keyPackageEventsJson: keyPackageEventsJson)
            logger.debug("✅ MDK addMembers succeeded")
            logger.debug("   Welcome rumors: \(result.welcomeRumorsJson?.count ?? 0)")
            return result
        } catch {
            logger.error("❌ MDK addMembers failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
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

    func acceptWelcome(welcome: Welcome) throws {
        logger.debug("=== acceptWelcome called ===")
        logger.debug("Welcome ID: \(welcome.id, privacy: .public)")

        let welcomeJson = try serializeWelcome(welcome)
        logger.debug("Serialized welcome JSON length: \(welcomeJson.count)")
        logger.debug("JSON preview: \(String(welcomeJson), privacy: .public)")

        try mdk.acceptWelcome(welcomeJson: welcomeJson)
        logger.debug("✅ SUCCESS: Welcome accepted!")
    }

    func declineWelcome(welcome: Welcome) throws {
        logger.debug("=== declineWelcome called ===")
        logger.debug("Welcome ID: \(welcome.id, privacy: .public)")

        let welcomeJson = try serializeWelcome(welcome)
        try mdk.declineWelcome(welcomeJson: welcomeJson)
        logger.debug("✅ SUCCESS: Welcome declined!")
    }

    func getPendingWelcomes() throws -> [Welcome] {
        let welcomes = try mdk.getPendingWelcomes()

        // Debug: Let's see what MDK actually stores and try to understand eventJson structure
        if let firstWelcome = welcomes.first {
            logger.debug("=== Sample Welcome from getPendingWelcomes ===")
            logger.debug("Welcome fields:")
            logger.debug("  id: \(firstWelcome.id)")
            logger.debug("  wrapperEventId: \(firstWelcome.wrapperEventId)")
            logger.debug("  mlsGroupId: \(firstWelcome.mlsGroupId)")
            logger.debug("  nostrGroupId: \(firstWelcome.nostrGroupId)")
            logger.debug("  eventJson length: \(firstWelcome.eventJson.count)")
            logger.debug("  eventJson is valid JSON: \((try? JSONSerialization.jsonObject(with: Data(firstWelcome.eventJson.utf8))) != nil)")

            // Is eventJson the Nostr event or something else?
            if let data = firstWelcome.eventJson.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                logger.debug("  eventJson top-level keys: \(json.keys.sorted().joined(separator: ", "))")
            }
        }

        return welcomes
    }

    // MARK: - Helper methods

    /// Converts a hex string to a byte array
    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            if let b = UInt8(hex[idx..<next], radix: 16) {
                bytes.append(b)
            }
            idx = next
        }
        return bytes
    }

    /// Converts optional byte data to proper array format for JSON serialization
    /// Returns nil if data is nil, otherwise returns [UInt8] array
    private func optionalBytes(_ data: Data?) -> [UInt8]? {
        guard let data else { return nil }
        return Array(data)
    }

    /// Serializes a Welcome object to JSON format expected by MDK
    private func serializeWelcome(_ welcome: Welcome) throws -> String {
        guard let eventObj = try? JSONSerialization.jsonObject(
            with: Data(welcome.eventJson.utf8)
        ) as? [String: Any] else {
            throw NSError(domain: "MdkActor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to parse eventJson"])
        }

        let payload: [String: Any?] = [
            "id": welcome.id,
            "event": eventObj,
            // VLBytes wrapper: GroupId { value: VLBytes } needs {"value": {"vec": [bytes]}}
            "mls_group_id": ["value": ["vec": hexToBytes(welcome.mlsGroupId)]],
            "nostr_group_id": hexToBytes(welcome.nostrGroupId),
            "group_name": welcome.groupName,
            "group_description": welcome.groupDescription,
            "group_image_hash": optionalBytes(welcome.groupImageHash),
            "group_image_key": optionalBytes(welcome.groupImageKey),
            "group_image_nonce": optionalBytes(welcome.groupImageNonce),
            "group_admin_pubkeys": welcome.groupAdminPubkeys,
            "group_relays": welcome.groupRelays,
            "welcomer": welcome.welcomer,
            "member_count": welcome.memberCount,
            "state": welcome.state,
            "wrapper_event_id": welcome.wrapperEventId
        ]

        let data = try JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        return String(data: data, encoding: .utf8)!
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
