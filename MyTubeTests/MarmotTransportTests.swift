//
//  MarmotTransportTests.swift
//  MyTubeTests
//
//  Created by Codex on 02/15/26.
//

import XCTest
@testable import MyTube
import MDKBindings
import NostrSDK

final class MarmotTransportTests: XCTestCase {
    func testPublishCreateGroupResultPublishesGiftWrappedWelcomes() async throws {
        let relayURL = URL(string: "wss://relay.marmot.test/\(UUID().uuidString)")!
        let nostrClient = await MainActor.run { RecordingNostrClient() }
        await MainActor.run {
            nostrClient.statuses = [RelayHealth(url: relayURL, status: .connected)]
        }
        let mdkActor = StubMdkActor()
        let groupId = "abcd\(UUID().uuidString.replacingOccurrences(of: "-", with: "") )"
        await mdkActor.setRelays(["\(relayURL.absoluteString)"], forGroup: groupId)

        let relayDirectory = makeRelayDirectory(suiteName: "MarmotTransportTests.publishCreateGroup")
        let welcomerPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let keyStore = StubKeyStore(parent: welcomerPair)
        let cryptoService = CryptoEnvelopeService()
        let transport = MarmotTransport(
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            mdkActor: mdkActor,
            keyStore: keyStore,
            cryptoService: cryptoService
        )

        let recipientPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let keyPackage = try makeEvent(kind: MarmotEventKind.keyPackage.rawValue, keyPair: recipientPair)
        let welcomeJson = try makeWelcomeRumor(
            welcomer: welcomerPair,
            keyPackageEvent: keyPackage.event,
            relays: [relayURL]
        )
        let result = CreateGroupResult(
            group: makeGroup(mlsGroupId: groupId),
            welcomeRumorsJson: [welcomeJson]
        )

        let publishResult = try await transport.publish(
            createGroupResult: result,
            keyPackageEventsJson: [keyPackage.json]
        )

        XCTAssertEqual(publishResult.groupId, groupId)
        XCTAssertEqual(publishResult.welcomeGiftWraps.count, 1)
        let publishedWrap = try XCTUnwrap(publishResult.welcomeGiftWraps.first)
        XCTAssertEqual(publishedWrap.kind().asU16(), MarmotEventKind.giftWrap.rawValue)
        let pTag = try XCTUnwrap(publishedWrap.rawTags.first { $0.first?.lowercased() == "p" })
        XCTAssertEqual(pTag.dropFirst().first, recipientPair.publicKeyHex.lowercased())

        await MainActor.run {
            XCTAssertEqual(nostrClient.publishedEvents.count, 1)
            XCTAssertEqual(nostrClient.publishedEvents.first?.event.idHex, publishedWrap.idHex)
            XCTAssertTrue(nostrClient.publishedEvents.allSatisfy { $0.relays == [relayURL] })
        }
        let mergedGroups = await mdkActor.mergedGroupIds()
        XCTAssertTrue(mergedGroups.isEmpty)

        let receivingActor = StubMdkActor()
        let receivingKeyStore = StubKeyStore(parent: recipientPair)
        let receivingClient = await MainActor.run { RecordingNostrClient() }
        let receivingTransport = MarmotTransport(
            nostrClient: receivingClient,
            relayDirectory: makeRelayDirectory(suiteName: "MarmotTransportTests.publishCreateGroup.receiving"),
            mdkActor: receivingActor,
            keyStore: receivingKeyStore,
            cryptoService: cryptoService
        )

        await receivingTransport.handleIncoming(event: publishedWrap)
        let processed = await receivingActor.processedWelcomePayloads()
        XCTAssertEqual(processed.first?.rumorJson, welcomeJson)
    }

    func testPublishAddMembersResultPublishesCommitAndGiftWrapsThenMerges() async throws {
        let relayURL = URL(string: "wss://relay.marmot.test/\(UUID().uuidString)")!
        let nostrClient = await MainActor.run { RecordingNostrClient() }
        await MainActor.run {
            nostrClient.statuses = [RelayHealth(url: relayURL, status: .connected)]
        }
        let mdkActor = StubMdkActor()
        let groupId = "dcba\(UUID().uuidString.replacingOccurrences(of: "-", with: "") )"
        await mdkActor.setRelays(["\(relayURL.absoluteString)"], forGroup: groupId)

        let relayDirectory = makeRelayDirectory(suiteName: "MarmotTransportTests.publishAddMembers")
        let welcomerPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let keyStore = StubKeyStore(parent: welcomerPair)
        let cryptoService = CryptoEnvelopeService()
        let transport = MarmotTransport(
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            mdkActor: mdkActor,
            keyStore: keyStore,
            cryptoService: cryptoService
        )

        let commitEvent = try makeEvent(kind: MarmotEventKind.group.rawValue, keyPair: welcomerPair)
        let recipientPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let keyPackage = try makeEvent(kind: MarmotEventKind.keyPackage.rawValue, keyPair: recipientPair)
        let welcomeJson = try makeWelcomeRumor(
            welcomer: welcomerPair,
            keyPackageEvent: keyPackage.event,
            relays: [relayURL]
        )
        let result = AddMembersResult(
            evolutionEventJson: commitEvent.json,
            welcomeRumorsJson: [welcomeJson],
            mlsGroupId: groupId
        )

        let publishResult = try await transport.publish(
            addMembersResult: result,
            keyPackageEventsJson: [keyPackage.json]
        )

        XCTAssertEqual(publishResult.groupId, groupId)
        XCTAssertEqual(publishResult.evolutionEvent.idHex, commitEvent.event.idHex)
        XCTAssertEqual(publishResult.welcomeGiftWraps.count, 1)
        XCTAssertEqual(publishResult.welcomeGiftWraps.first?.kind().asU16(), MarmotEventKind.giftWrap.rawValue)

        await MainActor.run {
            XCTAssertEqual(nostrClient.publishedEvents.count, 2)
            XCTAssertTrue(nostrClient.publishedEvents.allSatisfy { $0.relays == [relayURL] })
        }
        let mergedGroups = await mdkActor.mergedGroupIds()
        XCTAssertEqual(mergedGroups, [groupId])

        let receivingActor = StubMdkActor()
        let receivingKeyStore = StubKeyStore(parent: recipientPair)
        let receivingClient = await MainActor.run { RecordingNostrClient() }
        let receivingTransport = MarmotTransport(
            nostrClient: receivingClient,
            relayDirectory: makeRelayDirectory(suiteName: "MarmotTransportTests.publishAddMembers.receiving"),
            mdkActor: receivingActor,
            keyStore: receivingKeyStore,
            cryptoService: cryptoService
        )
        if let wrap = publishResult.welcomeGiftWraps.first {
            await receivingTransport.handleIncoming(event: wrap)
        }
        let processed = await receivingActor.processedWelcomePayloads()
        XCTAssertEqual(processed.first?.rumorJson, welcomeJson)
    }

    func testPublishRemoveMembersResultPublishesCommitAndMerges() async throws {
        let relayURL = URL(string: "wss://relay.marmot.test/\(UUID().uuidString)")!
        let nostrClient = await MainActor.run { RecordingNostrClient() }
        await MainActor.run {
            nostrClient.statuses = [RelayHealth(url: relayURL, status: .connected)]
        }
        let mdkActor = StubMdkActor()
        let groupId = "remove\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        await mdkActor.setRelays(["\(relayURL.absoluteString)"], forGroup: groupId)

        let relayDirectory = makeRelayDirectory(suiteName: "MarmotTransportTests.publishRemoveMembers")
        let keyPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let keyStore = StubKeyStore(parent: keyPair)
        let cryptoService = CryptoEnvelopeService()
        let transport = MarmotTransport(
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            mdkActor: mdkActor,
            keyStore: keyStore,
            cryptoService: cryptoService
        )

        let commitEvent = try makeEvent(kind: MarmotEventKind.group.rawValue, keyPair: keyPair)
        let result = GroupUpdateResult(
            evolutionEventJson: commitEvent.json,
            welcomeRumorsJson: nil,
            mlsGroupId: groupId
        )

        let publishResult = try await transport.publish(removeMembersResult: result)

        XCTAssertEqual(publishResult.groupId, groupId)
        XCTAssertEqual(publishResult.evolutionEvent.idHex, commitEvent.event.idHex)
        await MainActor.run {
            XCTAssertEqual(nostrClient.publishedEvents.count, 1)
            XCTAssertEqual(nostrClient.publishedEvents.first?.event.idHex, commitEvent.event.idHex)
            XCTAssertTrue(nostrClient.publishedEvents.allSatisfy { $0.relays == [relayURL] })
        }
        let mergedGroups = await mdkActor.mergedGroupIds()
        XCTAssertEqual(mergedGroups, [groupId])
    }

    func testHandleGiftWrapProcessesWelcome() async throws {
        let cryptoService = CryptoEnvelopeService()
        let nostrClient = await MainActor.run { RecordingNostrClient() }
        let relayDirectory = makeRelayDirectory(suiteName: "MarmotTransportTests.handleGiftWrap")
        let mdkActor = StubMdkActor()
        let parentPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let keyStore = StubKeyStore(parent: parentPair)
        let transport = MarmotTransport(
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            mdkActor: mdkActor,
            keyStore: keyStore,
            cryptoService: cryptoService
        )

        let welcomerPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let rumor = try makeEvent(kind: MarmotEventKind.welcome.rawValue)
        let giftWrap = try makeGiftWrap(
            rumorJson: rumor.json,
            welcomer: welcomerPair,
            recipient: parentPair,
            cryptoService: cryptoService
        )

        await transport.handleIncoming(event: giftWrap)

        let processed = await mdkActor.processedWelcomePayloads()
        XCTAssertEqual(processed.count, 1)
        XCTAssertEqual(processed.first?.wrapperId, giftWrap.idHex)
        XCTAssertEqual(processed.first?.rumorJson, rumor.json)
    }

    func testHandleGroupEventMergesCommitResult() async throws {
        let cryptoService = CryptoEnvelopeService()
        let nostrClient = await MainActor.run { RecordingNostrClient() }
        let relayDirectory = makeRelayDirectory(suiteName: "MarmotTransportTests.handleGroupEvent")
        let mdkActor = StubMdkActor()
        let groupId = "group-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        await mdkActor.enqueueProcessMessageResult(.commit(mlsGroupId: groupId))
        let transport = MarmotTransport(
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            mdkActor: mdkActor,
            keyStore: StubKeyStore(),
            cryptoService: cryptoService
        )

        let commitEvent = try makeEvent(kind: MarmotEventKind.group.rawValue)
        await transport.handleIncoming(event: commitEvent.event)

        let mergedGroups = await mdkActor.mergedGroupIds()
        let processedCount = await mdkActor.processedMessageCount()
        XCTAssertEqual(mergedGroups, [groupId])
        XCTAssertEqual(processedCount, 1)
    }

    func testHandleMessageKindProcessesApplicationMessage() async throws {
        let cryptoService = CryptoEnvelopeService()
        let nostrClient = await MainActor.run { RecordingNostrClient() }
        let relayDirectory = makeRelayDirectory(suiteName: "MarmotTransportTests.handleMessageKind")
        let mdkActor = StubMdkActor()
        let message = makeStubMessage(mlsGroupId: "mls-\(UUID().uuidString)")
        await mdkActor.enqueueProcessMessageResult(.applicationMessage(message: message))
        let transport = MarmotTransport(
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            mdkActor: mdkActor,
            keyStore: StubKeyStore(),
            cryptoService: cryptoService
        )

        let messageEvent = try makeEvent(kind: MarmotMessageKind.videoShare.rawValue)
        await transport.handleIncoming(event: messageEvent.event)

        let processedCount = await mdkActor.processedMessageCount()
        XCTAssertEqual(processedCount, 1)
    }

    // MARK: - Helpers

    private enum GiftWrapError: Error {
        case invalidEncoding
    }

    private func makeRelayDirectory(suiteName: String) -> RelayDirectory {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return RelayDirectory(userDefaults: defaults)
    }

    private func makeGroup(mlsGroupId: String) -> Group {
        Group(
            mlsGroupId: mlsGroupId,
            nostrGroupId: String(repeating: "0", count: 64),
            name: "Test Group",
            description: "Test",
            imageHash: nil,
            imageKey: nil,
            imageNonce: nil,
            adminPubkeys: [],
            lastMessageId: nil,
            lastMessageAt: nil,
            epoch: 0,
            state: "active"
        )
    }

    private func makeEvent(kind: UInt16, keyPair: NostrKeyPair? = nil, content: String? = nil) throws -> (event: NostrEvent, json: String) {
        let pair: NostrKeyPair
        if let keyPair {
            pair = keyPair
        } else {
            pair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        }
        let builder = NostrSDK.EventBuilder(
            kind: EventKind(kind: kind),
            content: content ?? UUID().uuidString
        )
        let event = try builder.signWithKeys(keys: pair.makeKeys())
        let json = try event.asJson()
        return (event, json)
    }

    private func makeWelcomeRumor(
        welcomer: NostrKeyPair,
        keyPackageEvent: NostrEvent,
        relays: [URL]
    ) throws -> String {
        let relayTag = ["relays"] + relays.map(\.absoluteString)
        let tags: [[String]] = [
            relayTag,
            ["e", keyPackageEvent.idHex]
        ]
        let payload: [String: Any] = [
            "id": randomHexString(),
            "kind": MarmotEventKind.welcome.rawValue,
            "pubkey": welcomer.publicKeyHex.lowercased(),
            "content": randomHexString(),
            "tags": tags
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw GiftWrapError.invalidEncoding
        }
        return json
    }

    private func randomHexString(byteCount: Int = 32) -> String {
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func makeStubMessage(mlsGroupId: String) -> Message {
        Message(
            id: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            mlsGroupId: mlsGroupId,
            nostrGroupId: String(repeating: "0", count: 64),
            eventId: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            eventJson: "{}",
            processedAt: UInt64(Date().timeIntervalSince1970),
            state: "processed"
        )
    }

    private func makeGiftWrap(
        rumorJson: String,
        welcomer: NostrKeyPair,
        recipient: NostrKeyPair,
        cryptoService: CryptoEnvelopeService
    ) throws -> NostrEvent {
        guard
            let rumorData = rumorJson.data(using: .utf8),
            let recipientData = Data(hexString: recipient.publicKeyHex.lowercased())
        else {
            throw GiftWrapError.invalidEncoding
        }

        let signer = NostrEventSigner()
        let sealCipher = try cryptoService.encryptGiftWrapEnvelope(
            rumorData,
            senderPrivateKeyData: welcomer.privateKeyData,
            recipientPublicKeyXOnly: recipientData
        )
        let sealEvent = try signer.makeEvent(
            kind: EventKind(kind: 13),
            tags: [],
            content: sealCipher,
            keyPair: welcomer
        )
        let sealJson = try sealEvent.asJson()
        guard let sealData = sealJson.data(using: .utf8) else {
            throw GiftWrapError.invalidEncoding
        }

        let ephemeralPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let wrapCipher = try cryptoService.encryptGiftWrapEnvelope(
            sealData,
            senderPrivateKeyData: ephemeralPair.privateKeyData,
            recipientPublicKeyXOnly: recipientData
        )
        let tags = [NostrTagBuilder.make(name: "p", value: recipient.publicKeyHex.lowercased())]
        return try signer.makeEvent(
            kind: EventKind(kind: MarmotEventKind.giftWrap.rawValue),
            tags: tags,
            content: wrapCipher,
            keyPair: ephemeralPair
        )
    }
}

// MARK: - Test Doubles

@MainActor
private final class RecordingNostrClient: NostrClient {
    struct Publication {
        let event: NostrEvent
        let relays: [URL]?
    }

    var publishedEvents: [Publication] = []
    var statuses: [RelayHealth] = []

    func connect(relays: [URL]) async throws {
        statuses = relays.map { RelayHealth(url: $0, status: .connected) }
    }

    func disconnect() async { }

    func publish(event: NostrEvent, to relays: [URL]?) async throws {
        publishedEvents.append(Publication(event: event, relays: relays))
    }

    func subscribe(id: String, filters: [Filter], on relays: [URL]?) async throws { }

    func unsubscribe(id: String, on relays: [URL]?) async { }

    func events() -> AsyncStream<NostrEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func relayStatuses() async -> [RelayHealth] {
        statuses
    }
}

private final class StubKeyStore: MarmotKeyStore {
    var parent: NostrKeyPair?
    var childPairs: [UUID: NostrKeyPair]

    init(parent: NostrKeyPair? = nil, childPairs: [UUID: NostrKeyPair] = [:]) {
        self.parent = parent
        self.childPairs = childPairs
    }

    func fetchKeyPair(role: NostrIdentityRole) throws -> NostrKeyPair? {
        switch role {
        case .parent:
            return parent
        case .child(let id):
            return childPairs[id]
        }
    }

    func childKeyIdentifiers() throws -> [UUID] {
        Array(childPairs.keys)
    }
}

private actor StubMdkActor: MarmotMdkClient {
    enum StubError: Error {
        case unimplemented
    }

    private var relaysByGroup: [String: [String]] = [:]
    private var mergedGroups: [String] = []
    private var processedWelcomes: [(wrapperId: String, rumorJson: String)] = []
    private var queuedProcessResults: [ProcessMessageResult] = []
    private var processedMessageJsons: [String] = []

    func setRelays(_ relays: [String], forGroup groupId: String) {
        relaysByGroup[groupId] = relays
    }

    func mergedGroupIds() -> [String] {
        mergedGroups
    }

    func createGroup(
        creatorPublicKey: String,
        memberKeyPackageEventsJson: [String],
        name: String,
        description: String,
        relays: [String],
        admins: [String]
    ) throws -> CreateGroupResult {
        throw StubError.unimplemented
    }

    func addMembers(mlsGroupId: String, keyPackageEventsJson: [String]) throws -> AddMembersResult {
        throw StubError.unimplemented
    }

    func removeMembers(mlsGroupId: String, memberPublicKeys: [String]) throws -> GroupUpdateResult {
        throw StubError.unimplemented
    }

    func parseKeyPackage(eventJson: String) throws {
        // No-op for these tests.
    }

    func processWelcome(wrapperEventId: String, rumorEventJson: String) throws -> Welcome {
        processedWelcomes.append((wrapperEventId, rumorJson: rumorEventJson))
        return Welcome(
            id: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            eventJson: rumorEventJson,
            mlsGroupId: "group",
            nostrGroupId: "nostrGroup",
            groupName: "Test",
            groupDescription: "Test",
            groupImageHash: nil,
            groupImageKey: nil,
            groupImageNonce: nil,
            groupAdminPubkeys: [],
            groupRelays: [],
            welcomer: "welcomer",
            memberCount: 1,
            state: "pending",
            wrapperEventId: wrapperEventId
        )
    }

    func processedWelcomePayloads() -> [(wrapperId: String, rumorJson: String)] {
        processedWelcomes
    }

    func enqueueProcessMessageResult(_ result: ProcessMessageResult) {
        queuedProcessResults.append(result)
    }

    func processedMessageCount() -> Int {
        processedMessageJsons.count
    }

    func getRelays(inGroup mlsGroupId: String) throws -> [String] {
        relaysByGroup[mlsGroupId] ?? []
    }

    func mergePendingCommit(mlsGroupId: String) throws {
        mergedGroups.append(mlsGroupId)
    }

    func processMessage(eventJson: String) throws -> ProcessMessageResult {
        processedMessageJsons.append(eventJson)
        guard !queuedProcessResults.isEmpty else {
            throw StubError.unimplemented
        }
        return queuedProcessResults.removeFirst()
    }
}
