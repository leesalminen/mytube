//
//  GroupMembershipCoordinatorTests.swift
//  MyTubeTests
//
//  Created by Codex on 02/17/26.
//

import XCTest
@testable import MyTube
import MDKBindings
import NostrSDK

final class GroupMembershipCoordinatorTests: XCTestCase {
    func testCreateGroupPassesKeyPackagesToTransport() async throws {
        let createResult = makeCreateGroupResult(groupId: "group-\(UUID().uuidString)")
        let addMembersResult = makeAddMembersResult(groupId: createResult.group.mlsGroupId)
        let updateResult = makeGroupUpdateResult(groupId: createResult.group.mlsGroupId)
        let mdkActor = RecordingMdkActor(
            createResult: createResult,
            addMembersResult: addMembersResult,
            removeMembersResult: updateResult
        )
        let transport = RecordingMarmotTransport()
        let coordinator = GroupMembershipCoordinator(mdkActor: mdkActor, marmotTransport: transport)

        let request = GroupMembershipCoordinator.CreateGroupRequest(
            creatorPublicKeyHex: "abcd1234",
            memberKeyPackageEventsJson: ["kp-one", "kp-two"],
            name: "Test Group",
            description: "Group Description",
            relays: ["wss://relay.example"],
            adminPublicKeys: ["abcd1234"],
            relayOverride: [URL(string: "wss://relay.example")!]
        )

        let response = try await coordinator.createGroup(request: request)

        XCTAssertEqual(response.result.group.mlsGroupId, createResult.group.mlsGroupId)
        let recordedCreate = await mdkActor.recordedCreateRequests().first
        XCTAssertEqual(recordedCreate?.memberKeyPackages, request.memberKeyPackageEventsJson)
        let recordedTransportCall = await transport.recordedCreateCalls.first
        XCTAssertEqual(recordedTransportCall?.keyPackages, request.memberKeyPackageEventsJson)
        XCTAssertEqual(recordedTransportCall?.relayOverride, request.relayOverride)
    }

    func testAddMembersPassesKeyPackagesToTransport() async throws {
        let createResult = makeCreateGroupResult(groupId: "group-\(UUID().uuidString)")
        let addMembersResult = makeAddMembersResult(groupId: createResult.group.mlsGroupId)
        let updateResult = makeGroupUpdateResult(groupId: createResult.group.mlsGroupId)
        let mdkActor = RecordingMdkActor(
            createResult: createResult,
            addMembersResult: addMembersResult,
            removeMembersResult: updateResult
        )
        let transport = RecordingMarmotTransport()
        let coordinator = GroupMembershipCoordinator(mdkActor: mdkActor, marmotTransport: transport)

        let request = GroupMembershipCoordinator.AddMembersRequest(
            mlsGroupId: createResult.group.mlsGroupId,
            keyPackageEventsJson: ["kp-new"],
            relayOverride: [URL(string: "wss://relay.two")!]
        )

        let response = try await coordinator.addMembers(request: request)

        XCTAssertEqual(response.result.mlsGroupId, createResult.group.mlsGroupId)
        let recordedAdd = await mdkActor.recordedAddMembersRequests().first
        XCTAssertEqual(recordedAdd?.mlsGroupId, request.mlsGroupId)
        XCTAssertEqual(recordedAdd?.keyPackages, request.keyPackageEventsJson)
        let transportCall = await transport.recordedAddMemberCalls.first
        XCTAssertEqual(transportCall?.keyPackages, request.keyPackageEventsJson)
        XCTAssertEqual(transportCall?.relayOverride, request.relayOverride)
    }

    func testRemoveMembersRoutesThroughTransport() async throws {
        let createResult = makeCreateGroupResult(groupId: "group-\(UUID().uuidString)")
        let addMembersResult = makeAddMembersResult(groupId: createResult.group.mlsGroupId)
        let updateResult = makeGroupUpdateResult(groupId: createResult.group.mlsGroupId)
        let mdkActor = RecordingMdkActor(
            createResult: createResult,
            addMembersResult: addMembersResult,
            removeMembersResult: updateResult
        )
        let transport = RecordingMarmotTransport()
        let coordinator = GroupMembershipCoordinator(mdkActor: mdkActor, marmotTransport: transport)

        let relay = URL(string: "wss://relay.remove")!
        let request = GroupMembershipCoordinator.RemoveMembersRequest(
            mlsGroupId: createResult.group.mlsGroupId,
            memberPublicKeys: ["abcd1234"],
            relayOverride: [relay]
        )

        let response = try await coordinator.removeMembers(request: request)

        XCTAssertEqual(response.result.mlsGroupId, createResult.group.mlsGroupId)
        let recordedRemove = await mdkActor.recordedRemoveMembersRequests().first
        XCTAssertEqual(recordedRemove?.mlsGroupId, request.mlsGroupId)
        XCTAssertEqual(recordedRemove?.memberKeys, request.memberPublicKeys)
        let transportCall = await transport.recordedRemoveMemberCalls.first
        XCTAssertEqual(transportCall?.relayOverride, request.relayOverride)
    }
}

// MARK: - Test Doubles

private actor RecordingMdkActor: MarmotMdkClient {
    struct CreateRequestRecord {
        let creatorPublicKey: String
        let memberKeyPackages: [String]
    }

    struct AddMembersRequestRecord {
        let mlsGroupId: String
        let keyPackages: [String]
    }

    struct RemoveMembersRequestRecord {
        let mlsGroupId: String
        let memberKeys: [String]
    }

    private var createRequests: [CreateRequestRecord] = []
    private var addMembersRequests: [AddMembersRequestRecord] = []
    private var removeMembersRequests: [RemoveMembersRequestRecord] = []

    private let createGroupResult: CreateGroupResult
    private let addMembersResult: AddMembersResult
    private let removeMembersResult: GroupUpdateResult

    init(
        createResult: CreateGroupResult,
        addMembersResult: AddMembersResult,
        removeMembersResult: GroupUpdateResult
    ) {
        self.createGroupResult = createResult
        self.addMembersResult = addMembersResult
        self.removeMembersResult = removeMembersResult
    }

    func recordedCreateRequests() -> [CreateRequestRecord] {
        createRequests
    }

    func recordedAddMembersRequests() -> [AddMembersRequestRecord] {
        addMembersRequests
    }

    func recordedRemoveMembersRequests() -> [RemoveMembersRequestRecord] {
        removeMembersRequests
    }

    func createGroup(
        creatorPublicKey: String,
        memberKeyPackageEventsJson: [String],
        name: String,
        description: String,
        relays: [String],
        admins: [String]
    ) throws -> CreateGroupResult {
        createRequests.append(
            CreateRequestRecord(
                creatorPublicKey: creatorPublicKey,
                memberKeyPackages: memberKeyPackageEventsJson
            )
        )
        return createGroupResult
    }

    func addMembers(mlsGroupId: String, keyPackageEventsJson: [String]) throws -> AddMembersResult {
        addMembersRequests.append(
            AddMembersRequestRecord(
                mlsGroupId: mlsGroupId,
                keyPackages: keyPackageEventsJson
            )
        )
        return addMembersResult
    }

    func removeMembers(mlsGroupId: String, memberPublicKeys: [String]) throws -> GroupUpdateResult {
        removeMembersRequests.append(
            RemoveMembersRequestRecord(
                mlsGroupId: mlsGroupId,
                memberKeys: memberPublicKeys
            )
        )
        return removeMembersResult
    }

    func parseKeyPackage(eventJson: String) throws { }

    func processWelcome(wrapperEventId: String, rumorEventJson: String) throws -> Welcome {
        throw StubError.unimplemented
    }

    func processMessage(eventJson: String) throws -> ProcessMessageResult {
        throw StubError.unimplemented
    }

    func getRelays(inGroup mlsGroupId: String) throws -> [String] {
        []
    }

    func mergePendingCommit(mlsGroupId: String) throws { }

    private enum StubError: Error {
        case unimplemented
    }
}

private actor RecordingMarmotTransport: MarmotPublishingTransport {
    struct CreateCallRecord {
        let keyPackages: [String]
        let relayOverride: [URL]?
    }

    struct AddMembersCallRecord {
        let keyPackages: [String]
        let relayOverride: [URL]?
    }

    struct RemoveMembersCallRecord {
        let relayOverride: [URL]?
    }

    private(set) var recordedCreateCalls: [CreateCallRecord] = []
    private(set) var recordedAddMemberCalls: [AddMembersCallRecord] = []
    private(set) var recordedRemoveMemberCalls: [RemoveMembersCallRecord] = []

    func publish(
        createGroupResult result: CreateGroupResult,
        keyPackageEventsJson: [String],
        relayOverride: [URL]?
    ) async throws -> MarmotTransport.CreateGroupPublishResult {
        recordedCreateCalls.append(CreateCallRecord(keyPackages: keyPackageEventsJson, relayOverride: relayOverride))
        return MarmotTransport.CreateGroupPublishResult(groupId: result.group.mlsGroupId, welcomeGiftWraps: [])
    }

    func publish(
        addMembersResult result: AddMembersResult,
        keyPackageEventsJson: [String],
        relayOverride: [URL]?
    ) async throws -> MarmotTransport.MemberUpdatePublishResult {
        recordedAddMemberCalls.append(
            AddMembersCallRecord(
                keyPackages: keyPackageEventsJson,
                relayOverride: relayOverride
            )
        )

        return MarmotTransport.MemberUpdatePublishResult(
            groupId: result.mlsGroupId,
            evolutionEvent: try makeEvent(kind: MarmotEventKind.group.rawValue).event,
            welcomeGiftWraps: []
        )
    }

    func publish(
        removeMembersResult result: GroupUpdateResult,
        relayOverride: [URL]?
    ) async throws -> MarmotTransport.MemberRemovalPublishResult {
        recordedRemoveMemberCalls.append(
            RemoveMembersCallRecord(
                relayOverride: relayOverride
            )
        )

        return MarmotTransport.MemberRemovalPublishResult(
            groupId: result.mlsGroupId,
            evolutionEvent: try makeEvent(kind: MarmotEventKind.group.rawValue).event
        )
    }
}

// MARK: - Helpers

private func makeCreateGroupResult(groupId: String) -> CreateGroupResult {
    CreateGroupResult(
        group: Group(
            mlsGroupId: groupId,
            nostrGroupId: String(repeating: "0", count: 64),
            name: "Test",
            description: "Test description",
            imageHash: nil,
            imageKey: nil,
            imageNonce: nil,
            adminPubkeys: [],
            lastMessageId: nil,
            lastMessageAt: nil,
            epoch: 0,
            state: "active"
        ),
        welcomeRumorsJson: ["{\"kind\":444,\"id\":\"\(UUID().uuidString)\"}"]
    )
}

private func makeAddMembersResult(groupId: String) -> AddMembersResult {
    let event = try! makeEvent(kind: MarmotEventKind.group.rawValue)
    return AddMembersResult(
        evolutionEventJson: event.json,
        welcomeRumorsJson: [],
        mlsGroupId: groupId
    )
}

private func makeGroupUpdateResult(groupId: String) -> GroupUpdateResult {
    let event = try! makeEvent(kind: MarmotEventKind.group.rawValue)
    return GroupUpdateResult(
        evolutionEventJson: event.json,
        welcomeRumorsJson: nil,
        mlsGroupId: groupId
    )
}

private func makeEvent(kind: UInt16) throws -> (event: NostrEvent, json: String) {
    let pair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
    let builder = NostrSDK.EventBuilder(kind: EventKind(kind: kind), content: UUID().uuidString)
    let event = try builder.signWithKeys(keys: pair.makeKeys())
    let json = try event.asJson()
    return (event, json)
}
