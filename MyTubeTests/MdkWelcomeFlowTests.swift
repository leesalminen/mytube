//
//  MdkWelcomeFlowTests.swift
//  MyTubeTests
//
//  Integration test for MDK welcome flow
//

import XCTest
import MDKBindings
import NostrSDK
@testable import MyTube

/// Test the complete MDK welcome flow with real MDK instances to understand data formats
final class MdkWelcomeFlowTests: XCTestCase {

    func testTwoFamiliesGroupInviteAndAccept() async throws {
        // Setup two families with their own MDK instances
        let familyA = try await Family.create(name: "Family A")
        let familyB = try await Family.create(name: "Family B")

        print("\n=== Family A ===")
        print("Parent: \(familyA.parentKeyPair.publicKeyHex)")
        print("Child: \(familyA.childKeyPair.publicKeyHex)")

        print("\n=== Family B ===")
        print("Parent: \(familyB.parentKeyPair.publicKeyHex)")
        print("Child: \(familyB.childKeyPair.publicKeyHex)")

        // Step 1: Family A creates a group with their child
        print("\n=== Step 1: Family A creates group ===")
        let relays = ["wss://relay.test"]

        let familyAChildKeyPackage = try await familyA.createKeyPackageEvent(
            publicKey: familyA.childKeyPair.publicKeyHex,
            relays: relays
        )
        print("Family A child key package created")

        let familyBParentKeyPackage = try await familyB.createKeyPackageEvent(
            publicKey: familyB.parentKeyPair.publicKeyHex,
            relays: relays
        )
        print("Family B parent key package created")

        // Parse the key packages first (this is what would happen when receiving them)
        try await familyA.mdkActor.parseKeyPackage(eventJson: familyAChildKeyPackage)
        try await familyA.mdkActor.parseKeyPackage(eventJson: familyBParentKeyPackage)

        // Family A creates group and invites Family B parent
        let createResult = try await familyA.mdkActor.createGroup(
            creatorPublicKey: familyA.parentKeyPair.publicKeyHex,
            memberKeyPackageEventsJson: [
                familyAChildKeyPackage,
                familyBParentKeyPackage
            ],
            name: "Test Family Group",
            description: "Integration test group",
            relays: relays,
            admins: [familyA.parentKeyPair.publicKeyHex]
        )

        print("Group created: \(createResult.group.mlsGroupId)")
        print("Welcome rumors count: \(createResult.welcomeRumorsJson.count)")

        // Step 2: Family B receives and processes the welcome
        print("\n=== Step 2: Family B processes welcome ===")

        guard let welcomeRumorJson = createResult.welcomeRumorsJson.first else {
            XCTFail("No welcome rumors generated")
            return
        }

        print("Welcome rumor JSON length: \(welcomeRumorJson.count) chars")
        print("Welcome rumor preview: \(String(welcomeRumorJson.prefix(200)))...")

        // Process the welcome (this is what happens when they receive the gift-wrapped invite)
        // Event IDs must be 64-char hex strings (32 bytes)
        let wrapperEventId = String(repeating: "f", count: 64)
        let welcome = try await familyB.mdkActor.processWelcome(
            wrapperEventId: wrapperEventId,
            rumorEventJson: welcomeRumorJson
        )

        print("Welcome processed:")
        print("  ID: \(welcome.id)")
        print("  Group name: \(welcome.groupName)")
        print("  MLS Group ID: \(welcome.mlsGroupId)")
        print("  State: \(welcome.state)")
        print("  Event JSON length: \(welcome.eventJson.count) chars")

        // Write to file so we can inspect it
        let debugFile = "/tmp/welcome_eventjson_debug.txt"
        try? welcome.eventJson.write(toFile: debugFile, atomically: true, encoding: .utf8)
        print("  Event JSON written to: \(debugFile)")
        print("---")

        // Step 3: Family B accepts the welcome
        print("\n=== Step 3: Family B accepts welcome ===")

        // Pass the Welcome object directly to acceptWelcome
        try await familyB.mdkActor.acceptWelcome(welcome: welcome)
        print("✅ SUCCESS: Welcome accepted!")

        // Step 4: Verify both families can see the group
        print("\n=== Step 4: Verify group membership ===")

        let familyAGroups = try await familyA.mdkActor.getGroups()
        print("Family A sees \(familyAGroups.count) group(s)")
        if familyAGroups.count > 0 {
            print("  Group: \(familyAGroups[0].mlsGroupId)")
        }
        XCTAssertEqual(familyAGroups.count, 1)

        let familyBGroups = try await familyB.mdkActor.getGroups()
        print("Family B sees \(familyBGroups.count) group(s)")
        if familyBGroups.count > 0 {
            print("  Group: \(familyBGroups[0].mlsGroupId)")
        }

        // Only continue if Family B actually joined the group
        guard familyBGroups.count > 0 else {
            XCTFail("Family B did not join the group after accepting the welcome")
            return
        }

        // Verify they see the same group
        let groupA = familyAGroups.first!
        let groupB = familyBGroups.first!
        print("Family A group: \(groupA.mlsGroupId)")
        print("Family B group: \(groupB.mlsGroupId)")
        XCTAssertEqual(groupA.mlsGroupId, groupB.mlsGroupId)

        // Check members
        let membersA = try await familyA.mdkActor.getMembers(inGroup: groupA.mlsGroupId)
        let membersB = try await familyB.mdkActor.getMembers(inGroup: groupB.mlsGroupId)
        print("Family A sees \(membersA.count) members: \(membersA)")
        print("Family B sees \(membersB.count) members: \(membersB)")

        print("\n=== Test Complete ===")
    }

    // Helper to reconstruct Welcome as JSON
    private func reconstructWelcomeJson(_ welcome: Welcome) throws -> String {
        var dict: [String: Any] = [
            "id": welcome.id,
            "mls_group_id": welcome.mlsGroupId,
            "nostr_group_id": welcome.nostrGroupId,
            "group_name": welcome.groupName,
            "group_description": welcome.groupDescription,
            "group_admin_pubkeys": welcome.groupAdminPubkeys,
            "group_relays": welcome.groupRelays,
            "welcomer": welcome.welcomer,
            "member_count": welcome.memberCount,
            "state": welcome.state,
            "wrapper_event_id": welcome.wrapperEventId
        ]

        // Parse eventJson and include it
        if let eventData = welcome.eventJson.data(using: .utf8),
           let eventObject = try? JSONSerialization.jsonObject(with: eventData) {
            dict["event"] = eventObject
        }

        // Add optional fields
        if let hash = welcome.groupImageHash {
            dict["group_image_hash"] = Array(hash)
        }
        if let key = welcome.groupImageKey {
            dict["group_image_key"] = Array(key)
        }
        if let nonce = welcome.groupImageNonce {
            dict["group_image_nonce"] = Array(nonce)
        }

        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}

// MARK: - Test Helper: Family

private actor Family {
    let name: String
    let mdkActor: MdkActor
    let parentKeyPair: NostrKeyPair
    let childKeyPair: NostrKeyPair
    let cryptoService: CryptoEnvelopeService

    static func create(name: String) async throws -> Family {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MdkWelcomeFlowTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbURL = tempDir.appendingPathComponent("mdk.sqlite")
        let mdkActor = try MdkActor(databaseURL: dbURL)

        let parentKeyPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let childKeyPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())

        return Family(
            name: name,
            mdkActor: mdkActor,
            parentKeyPair: parentKeyPair,
            childKeyPair: childKeyPair,
            cryptoService: CryptoEnvelopeService()
        )
    }

    init(name: String, mdkActor: MdkActor, parentKeyPair: NostrKeyPair, childKeyPair: NostrKeyPair, cryptoService: CryptoEnvelopeService) {
        self.name = name
        self.mdkActor = mdkActor
        self.parentKeyPair = parentKeyPair
        self.childKeyPair = childKeyPair
        self.cryptoService = cryptoService
    }

    func createKeyPackageEvent(publicKey: String, relays: [String]) async throws -> String {
        let result = try await mdkActor.createKeyPackage(forPublicKey: publicKey, relays: relays)

        // Sign the key package as a Nostr event
        let signer = NostrEventSigner()
        let keyPair = publicKey == parentKeyPair.publicKeyHex ? parentKeyPair : childKeyPair

        let relayTag = NostrTagBuilder.make(
            name: "relays",
            value: relays.first ?? "wss://relay.test",
            otherParameters: Array(relays.dropFirst())
        )

        let event = try signer.makeEvent(
            kind: EventKind(kind: MarmotEventKind.keyPackage.rawValue),
            tags: [relayTag],
            content: result.keyPackage,
            keyPair: keyPair
        )

        return try event.asJson()
    }
}
