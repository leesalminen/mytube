//
//  MarmotTransport.swift
//  MyTube
//
//  Created by Codex on 02/14/26.
//

import Foundation
import MDKBindings
import NostrSDK
import OSLog

actor MarmotTransport {
    struct CreateGroupPublishResult {
        let groupId: String
        let welcomeGiftWraps: [NostrEvent]
    }

    struct MemberUpdatePublishResult {
        let groupId: String
        let evolutionEvent: NostrEvent
        let welcomeGiftWraps: [NostrEvent]
    }

    struct MemberRemovalPublishResult {
        let groupId: String
        let evolutionEvent: NostrEvent
    }

    private struct RawUnsignedEvent: Decodable {
        let id: String?
        let pubkey: String
        let kind: UInt16
        let content: String
        let tags: [[String]]?

        func tagValue(named name: String) -> String? {
            guard let tags else { return nil }
            for tag in tags {
                guard let tagName = tag.first else { continue }
                if tagName.caseInsensitiveCompare(name) == .orderedSame, tag.count > 1 {
                    return tag[1]
                }
            }
            return nil
        }
    }

    enum TransportError: Error {
        case invalidEventJson
        case noRelaysConfigured
        case relaysUnavailable
        case missingKeyPackageReference
        case welcomeRecipientNotFound
        case signingKeyUnavailable
        case rumorEncodingFailed
    }

    private let nostrClient: NostrClient
    private let relayDirectory: RelayDirectory
    private let mdkActor: any MarmotMdkClient
    private let keyStore: MarmotKeyStore
    private let cryptoService: CryptoEnvelopeService
    private let eventSigner = NostrEventSigner()
    private let maxLoggedPayloadLength = 256
    private let logger = Logger(subsystem: "com.mytube", category: "MarmotTransport")

    init(
        nostrClient: NostrClient,
        relayDirectory: RelayDirectory,
        mdkActor: any MarmotMdkClient,
        keyStore: MarmotKeyStore,
        cryptoService: CryptoEnvelopeService
    ) {
        self.nostrClient = nostrClient
        self.relayDirectory = relayDirectory
        self.mdkActor = mdkActor
        self.keyStore = keyStore
        self.cryptoService = cryptoService
    }

    @discardableResult
    func publish(jsonEvent: String, relayOverride: [URL]? = nil) async throws -> NostrEvent {
        let event = try decodeEvent(from: jsonEvent)
        let relays = try await resolveRelays(override: relayOverride)
        let pubkey = event.pubkey.prefix(16)
        logger.info("📤 Publishing kind \(event.kind().asU16()) id \(event.idHex.prefix(16), privacy: .public)... (pubkey: \(pubkey)...) to \(relays.count) relay(s)")
        for relay in relays {
            logger.debug("      → \(relay.absoluteString)")
        }
        try await nostrClient.publish(event: event, to: relays)
        logger.info("   ✅ Published kind \(event.kind().asU16()) id \(event.idHex.prefix(16), privacy: .public)...")
        return event
    }

    @discardableResult
    func publish(jsonEvents: [String], relayOverride: [URL]? = nil) async throws -> [NostrEvent] {
        guard !jsonEvents.isEmpty else { return [] }
        let relays = try await resolveRelays(override: relayOverride)
        var published: [NostrEvent] = []
        published.reserveCapacity(jsonEvents.count)
        for json in jsonEvents {
            let event = try decodeEvent(from: json)
            try await nostrClient.publish(event: event, to: relays)
            published.append(event)
            logger.debug("Published Marmot batch event kind \(event.kind().asU16()) id \(event.idHex, privacy: .public)")
        }
        return published
    }

    @discardableResult
    func publish(event: NostrEvent, relayOverride: [URL]? = nil) async throws -> NostrEvent {
        let relays = try await resolveRelays(override: relayOverride)
        try await nostrClient.publish(event: event, to: relays)
        logger.debug("Published Marmot event kind \(event.kind().asU16()) id \(event.idHex, privacy: .public)")
        return event
    }

    @discardableResult
    func publish(events: [NostrEvent], relayOverride: [URL]? = nil) async throws -> [NostrEvent] {
        guard !events.isEmpty else { return [] }
        let relays = try await resolveRelays(override: relayOverride)
        for event in events {
            try await nostrClient.publish(event: event, to: relays)
            logger.debug("Published Marmot event kind \(event.kind().asU16()) id \(event.idHex, privacy: .public)")
        }
        return events
    }

    func handleIncoming(event: NostrEvent) async {
        let kindValue = event.kind().asU16()
        if let kind = MarmotEventKind(rawValue: kindValue) {
            logger.debug("🔔 MarmotTransport.handleIncoming: kind \(kindValue) id \(event.idHex.prefix(16))...")
            do {
                switch kind {
                case .keyPackage:
                    try await ingestKeyPackage(event)
                case .group:
                    logger.debug("   ➡️ Processing group evolution event...")
                    try await ingestGroupEvent(event)
                    logger.debug("   ✅ Group event processed")
                case .welcome:
                    try await ingestWelcome(event, wrapperId: event.idHex)
                case .giftWrap:
                    try await ingestGiftWrap(event)
                }
            } catch {
                logger.error("Marmot ingest failed for kind \(kindValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        if MarmotMessageKind(rawValue: kindValue) != nil {
            do {
                try await ingestApplicationMessage(event)
            } catch {
                logger.error("Marmot message ingest failed for kind \(kindValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Publishing helpers

    @discardableResult
    func publish(createGroupResult result: CreateGroupResult, keyPackageEventsJson: [String], relayOverride: [URL]? = nil) async throws -> CreateGroupPublishResult {
        logger.debug("📤 Publishing create group result:")
        logger.debug("   Group ID: \(result.group.mlsGroupId.prefix(16))...")
        logger.debug("   Welcome rumors: \(result.welcomeRumorsJson.count)")
        logger.debug("   Key package events: \(keyPackageEventsJson.count)")
        
        let overrideRelays = await preferredRelayOverride(forGroupId: result.group.mlsGroupId, fallback: relayOverride)
        let giftWraps = try wrapWelcomeRumors(result.welcomeRumorsJson, keyPackageEventsJson: keyPackageEventsJson)
        
        logger.debug("   Generated \(giftWraps.count) gift wrap(s)")
        for (i, wrap) in giftWraps.enumerated() {
            logger.debug("   Gift wrap [\(i)] to: \(wrap.pubkey.prefix(16))...")
        }
        
        let publishedGiftWraps = try await publish(events: giftWraps, relayOverride: overrideRelays)
        logger.debug("Published \(publishedGiftWraps.count) Marmot welcome gift wraps for group \(result.group.mlsGroupId, privacy: .public)")
        return CreateGroupPublishResult(groupId: result.group.mlsGroupId, welcomeGiftWraps: publishedGiftWraps)
    }

    @discardableResult
    func publish(addMembersResult result: AddMembersResult, keyPackageEventsJson: [String], relayOverride: [URL]? = nil) async throws -> MemberUpdatePublishResult {
        let overrideRelays = await preferredRelayOverride(forGroupId: result.mlsGroupId, fallback: relayOverride)
        logger.info("Publishing add-members evolution for group \(result.mlsGroupId, privacy: .public)")
        let evolutionEvent = try await publish(jsonEvent: result.evolutionEventJson, relayOverride: overrideRelays)
        let welcomeGiftWraps: [NostrEvent]
        if let welcomeRumors = result.welcomeRumorsJson, !welcomeRumors.isEmpty {
            let wraps = try wrapWelcomeRumors(welcomeRumors, keyPackageEventsJson: keyPackageEventsJson)
            welcomeGiftWraps = try await publish(events: wraps, relayOverride: overrideRelays)
        } else {
            welcomeGiftWraps = []
        }
        do {
            try await mdkActor.mergePendingCommit(mlsGroupId: result.mlsGroupId)
        } catch {
            logger.error("Failed to merge MDK commit for group \(result.mlsGroupId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        logger.debug("Published Marmot add-members event \(evolutionEvent.idHex, privacy: .public) for group \(result.mlsGroupId, privacy: .public)")
        return MemberUpdatePublishResult(groupId: result.mlsGroupId, evolutionEvent: evolutionEvent, welcomeGiftWraps: welcomeGiftWraps)
    }

    @discardableResult
    func publish(removeMembersResult result: GroupUpdateResult, relayOverride: [URL]? = nil) async throws -> MemberRemovalPublishResult {
        let overrideRelays = await preferredRelayOverride(forGroupId: result.mlsGroupId, fallback: relayOverride)
        logger.info("Publishing remove-members evolution for group \(result.mlsGroupId, privacy: .public)")
        let evolutionEvent = try await publish(jsonEvent: result.evolutionEventJson, relayOverride: overrideRelays)
        if let welcomeRumors = result.welcomeRumorsJson, !welcomeRumors.isEmpty {
            logger.warning("Remove-members result unexpectedly contained \(welcomeRumors.count) welcome rumors for group \(result.mlsGroupId, privacy: .public); skipping publish.")
        }
        do {
            try await mdkActor.mergePendingCommit(mlsGroupId: result.mlsGroupId)
        } catch {
            logger.error("Failed to merge MDK commit after removal for group \(result.mlsGroupId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        logger.debug("Published Marmot remove-members event \(evolutionEvent.idHex, privacy: .public) for group \(result.mlsGroupId, privacy: .public)")
        return MemberRemovalPublishResult(groupId: result.mlsGroupId, evolutionEvent: evolutionEvent)
    }

    @discardableResult
    func publishMessage(mlsGroupId: String, eventJson: String, relayOverride: [URL]? = nil) async throws -> NostrEvent {
        logger.info("Publishing Marmot application message for group \(mlsGroupId, privacy: .public)")
        let overrideRelays = await preferredRelayOverride(forGroupId: mlsGroupId, fallback: relayOverride)
        return try await publish(jsonEvent: eventJson, relayOverride: overrideRelays)
    }

    private func decodeEvent(from json: String) throws -> NostrEvent {
        do {
            return try NostrEvent.fromJson(json: json)
        } catch {
            logger.error("Invalid Marmot event JSON: \(error.localizedDescription, privacy: .public) payload=\(self.redact(json), privacy: .public)")
            throw TransportError.invalidEventJson
        }
    }

    private func resolveRelays(override: [URL]?) async throws -> [URL] {
        let configured: [URL]
        if let override, !override.isEmpty {
            configured = override
        } else {
            configured = await relayDirectory.currentRelayURLs()
        }
        guard !configured.isEmpty else {
            throw TransportError.noRelaysConfigured
        }

        let connectedSet = Set(
            (await nostrClient.relayStatuses())
                .filter { $0.status == .connected }
                .map(\.url)
        )
        let filtered = configured.filter { connectedSet.contains($0) }

        guard !filtered.isEmpty else {
            throw TransportError.relaysUnavailable
        }
        return filtered
    }

    private func preferredRelayOverride(forGroupId groupId: String, fallback: [URL]?) async -> [URL]? {
        if let fallback, !fallback.isEmpty {
            return fallback
        }

        do {
            let storedRelays = try await mdkActor.getRelays(inGroup: groupId)
            let urls = storedRelays.compactMap { URL(string: $0) }
            if urls.isEmpty {
                logger.debug("Group \(groupId, privacy: .public) does not have per-group relays configured.")
                return nil
            }
            return urls
        } catch {
            logger.error("Unable to load relays for group \(groupId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func wrapWelcomeRumors(_ welcomeRumorsJson: [String], keyPackageEventsJson: [String]) throws -> [NostrEvent] {
        guard !welcomeRumorsJson.isEmpty else { return [] }
        let keyPackageIndex = try buildKeyPackageIndex(from: keyPackageEventsJson)
        guard !keyPackageIndex.isEmpty else {
            logger.error("Missing key package metadata for Marmot welcomes.")
            throw TransportError.welcomeRecipientNotFound
        }

        let signingKeyMap = signingKeyPairsByPublicKey()
        guard !signingKeyMap.isEmpty else {
            logger.error("No local signing keys available to wrap Marmot welcomes.")
            throw TransportError.signingKeyUnavailable
        }

        var wraps: [NostrEvent] = []
        wraps.reserveCapacity(welcomeRumorsJson.count)

        for (i, rumorJson) in welcomeRumorsJson.enumerated() {
            let rumor = try decodeUnsignedEvent(from: rumorJson)
            let welcomerHex = rumor.pubkey.lowercased()
            logger.debug("💌 Welcome rumor [\(i)]: welcomer=\(welcomerHex.prefix(16))...")
            
            guard let welcomerKeyPair = signingKeyMap[welcomerHex] else {
                logger.error("Unable to locate signing key for welcomer \(welcomerHex, privacy: .public)")
                throw TransportError.signingKeyUnavailable
            }
            guard let referencedEventId = rumor.tagValue(named: "e")?.lowercased() else {
                logger.error("Welcome rumor missing key package reference.")
                throw TransportError.missingKeyPackageReference
            }
            logger.debug("   References event ID: \(referencedEventId.prefix(16))...")
            logger.debug("   Key package index keys: \(Array(keyPackageIndex.keys).map { $0.prefix(16) })")
            
            guard let recipientHex = keyPackageIndex[referencedEventId] else {
                logger.error("No matching key package for welcome reference \(referencedEventId, privacy: .public)")
                logger.error("Available event IDs in index: \(Array(keyPackageIndex.keys))")
                throw TransportError.welcomeRecipientNotFound
            }
            logger.debug("   Recipient from index: \(recipientHex.prefix(16))...")

            let giftWrap = try makeGiftWrap(
                rumorJson: rumorJson,
                welcomerKeyPair: welcomerKeyPair,
                recipientPublicKeyHex: recipientHex
            )
            logger.debug("   Gift wrap created:")
            logger.debug("     Event ID: \(giftWrap.idHex.prefix(16))...")
            logger.debug("     Pubkey (ephemeral): \(giftWrap.pubkey.prefix(16))...")
            // Log p tags if present
            if let pTag = giftWrap.rawTags.first(where: { $0.first?.lowercased() == "p" }) {
                let pValue = pTag.dropFirst().first ?? "none"
                logger.debug("     P tag: \(pValue.prefix(16))...")
            } else {
                logger.debug("     P tag: none")
            }
            wraps.append(giftWrap)
        }

        return wraps
    }

    private func buildKeyPackageIndex(from events: [String]) throws -> [String: String] {
        guard !events.isEmpty else { return [:] }
        var index: [String: String] = [:]
        index.reserveCapacity(events.count)

        for (i, json) in events.enumerated() {
            let event = try decodeEvent(from: json)
            let idHex = event.idHex.lowercased()
            let pubkey = event.pubkey.lowercased()
            logger.debug("📋 Key package [\(i)] event ID: \(idHex.prefix(16))... pubkey: \(pubkey.prefix(16))...")
            index[idHex] = pubkey
        }

        return index
    }

    private func decodeUnsignedEvent(from json: String) throws -> RawUnsignedEvent {
        guard let data = json.data(using: .utf8) else {
            throw TransportError.invalidEventJson
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(RawUnsignedEvent.self, from: data)
        } catch {
            logger.error("Failed to decode unsigned Marmot event: \(error.localizedDescription, privacy: .public) payload=\(self.redact(json), privacy: .public)")
            throw TransportError.invalidEventJson
        }
    }

    private func makeGiftWrap(
        rumorJson: String,
        welcomerKeyPair: NostrKeyPair,
        recipientPublicKeyHex: String
    ) throws -> NostrEvent {
        guard let rumorData = rumorJson.data(using: .utf8),
              let recipientData = Data(hexString: recipientPublicKeyHex)
        else {
            throw TransportError.rumorEncodingFailed
        }

        let sealCipher = try cryptoService.encryptGiftWrapEnvelope(
            rumorData,
            senderPrivateKeyData: welcomerKeyPair.privateKeyData,
            recipientPublicKeyXOnly: recipientData
        )

        let sealEvent = try eventSigner.makeEvent(
            kind: EventKind(kind: 13),
            tags: [],
            content: sealCipher,
            keyPair: welcomerKeyPair
        )

        guard let sealJson = try? sealEvent.asJson(), let sealData = sealJson.data(using: .utf8) else {
            throw TransportError.rumorEncodingFailed
        }

        let ephemeralPair = try NostrKeyPair(secretKey: NostrSDK.SecretKey.generate())
        let wrapCipher = try cryptoService.encryptGiftWrapEnvelope(
            sealData,
            senderPrivateKeyData: ephemeralPair.privateKeyData,
            recipientPublicKeyXOnly: recipientData
        )
        let tag = NostrTagBuilder.make(name: "p", value: recipientPublicKeyHex.lowercased())
        return try eventSigner.makeEvent(
            kind: EventKind(kind: MarmotEventKind.giftWrap.rawValue),
            tags: [tag],
            content: wrapCipher,
            keyPair: ephemeralPair
        )
    }

    private func signingKeyPairsByPublicKey() -> [String: NostrKeyPair] {
        var map: [String: NostrKeyPair] = [:]
        for pair in loadSigningKeyPairs() {
            map[pair.publicKeyHex.lowercased()] = pair
        }
        return map
    }

    // MARK: - Ingest helpers

    private func ingestKeyPackage(_ event: NostrEvent) async throws {
        let json = try event.asJson()
        try await mdkActor.parseKeyPackage(eventJson: json)
        logger.debug("Parsed Marmot key package \(event.idHex, privacy: .public)")
    }

    private func ingestWelcome(_ event: NostrEvent, wrapperId: String) async throws {
        let json = try event.asJson()
        try await processWelcome(rumorJson: json, wrapperId: wrapperId)
    }

    private func ingestGroupEvent(_ event: NostrEvent) async throws {
        try await processMarmotMessage(event)
    }

    private func ingestGiftWrap(_ event: NostrEvent) async throws {
        guard let rumorJson = try decryptGiftWrap(event) else {
            logger.warning("Unable to decrypt gift wrap \(event.idHex, privacy: .public); no local key matched.")
            return
        }
        try await processWelcome(rumorJson: rumorJson, wrapperId: event.idHex)
    }

    private func ingestApplicationMessage(_ event: NostrEvent) async throws {
        try await processMarmotMessage(event)
    }

    private func processWelcome(rumorJson: String, wrapperId: String) async throws {
        _ = try await mdkActor.processWelcome(wrapperEventId: wrapperId, rumorEventJson: rumorJson)
        
        // Post notifications on main thread
        Task { @MainActor in
            NotificationCenter.default.post(name: .marmotPendingWelcomesDidChange, object: nil)
        }
        postMarmotStateDidChange()
        
        logger.debug("Processed Marmot welcome \(wrapperId, privacy: .public)")
    }

    private func processMarmotMessage(_ event: NostrEvent) async throws {
        logger.debug("📨 Processing Marmot message event \(event.idHex.prefix(16), privacy: .public)")
        let json = try event.asJson()
        let result = try await mdkActor.processMessage(eventJson: json)
        logger.debug("   ✅ MDK processed message, result type: \(String(describing: result))")
        await handleProcessMessageResult(result, eventId: event.idHex)
    }

    private func handleProcessMessageResult(
        _ result: ProcessMessageResult,
        eventId: String
    ) async {
        switch result {
        case .applicationMessage(let message):
            logger.info("✅ Processed Marmot application message \(eventId.prefix(16), privacy: .public) in group \(message.mlsGroupId.prefix(16), privacy: .public)")
            postMarmotStateDidChange()
            postMarmotMessagesDidChange(groupId: message.mlsGroupId)

        case .proposal(let update):
            logger.info("Received Marmot proposal for group \(update.mlsGroupId, privacy: .public); awaiting admin action.")

        case .externalJoinProposal(let groupId):
            logger.info("Received external join proposal for group \(groupId, privacy: .public)")

        case .commit(let groupId):
            do {
                try await mdkActor.mergePendingCommit(mlsGroupId: groupId)
                logger.debug("Merged Marmot commit for group \(groupId, privacy: .public)")
                postMarmotStateDidChange()
                postMarmotMessagesDidChange(groupId: groupId)
            } catch {
                logger.error("Failed to merge Marmot commit for group \(groupId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

        case .unprocessable(let groupId):
            logger.warning("Unable to process Marmot message \(eventId, privacy: .public) for group \(groupId, privacy: .public)")
        }
    }

    private func decryptGiftWrap(_ event: NostrEvent) throws -> String? {
        let candidates = loadSigningKeyPairs()
        guard !candidates.isEmpty else {
            logger.warning("No local signing keys available to unwrap gift wrap \(event.idHex, privacy: .public)")
            return nil
        }

        for candidate in candidates {
            do {
                return try decryptGiftWrap(event: event, with: candidate)
            } catch let error as CryptoEnvelopeError {
                logger.debug("Gift wrap decrypt failed for candidate key \(candidate.publicKeyHex.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            } catch TransportError.invalidEventJson {
                throw TransportError.invalidEventJson
            } catch {
                logger.debug("Gift wrap decrypt error for candidate key \(candidate.publicKeyHex.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        return nil
    }

    private func decryptGiftWrap(event: NostrEvent, with recipient: NostrKeyPair) throws -> String {
        guard let wrapperAuthor = Data(hexString: event.pubkey) else {
            throw TransportError.invalidEventJson
        }

        let sealData = try cryptoService.decryptGiftWrapEnvelope(
            event.content(),
            recipientPrivateKeyData: recipient.privateKeyData,
            senderPublicKeyXOnly: wrapperAuthor
        )
        guard let sealJson = String(data: sealData, encoding: .utf8) else {
            throw TransportError.invalidEventJson
        }
        let sealEvent = try decodeEvent(from: sealJson)
        guard let welcomerKey = Data(hexString: sealEvent.pubkey) else {
            throw TransportError.invalidEventJson
        }
        let rumorData = try cryptoService.decryptGiftWrapEnvelope(
            sealEvent.content(),
            recipientPrivateKeyData: recipient.privateKeyData,
            senderPublicKeyXOnly: welcomerKey
        )
        guard let rumorJson = String(data: rumorData, encoding: .utf8) else {
            throw TransportError.invalidEventJson
        }
        return rumorJson
    }

    private func postMarmotStateDidChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .marmotStateDidChange, object: nil)
        }
    }

    private func postMarmotMessagesDidChange(groupId: String) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .marmotMessagesDidChange,
                object: nil,
                userInfo: ["mlsGroupId": groupId]
            )
        }
    }

    private func loadSigningKeyPairs() -> [NostrKeyPair] {
        var pairs: [NostrKeyPair] = []
        if let parent = try? keyStore.fetchKeyPair(role: .parent) {
            pairs.append(parent)
        }
        if let identifiers = try? keyStore.childKeyIdentifiers() {
            for id in identifiers {
                if let child = try? keyStore.fetchKeyPair(role: .child(id: id)) {
                    pairs.append(child)
                }
            }
        }
        return pairs
    }

    private func redact(_ json: String) -> String {
        if json.count <= maxLoggedPayloadLength {
            return json
        }
        let prefix = json.prefix(maxLoggedPayloadLength)
        return "\(prefix)…"
    }
}

extension MarmotTransport.TransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidEventJson:
            return "The Marmot event JSON was invalid."
        case .noRelaysConfigured:
            return "No relays are configured for Marmot publishing."
        case .relaysUnavailable:
            return "Unable to publish because none of the configured relays are connected."
        case .missingKeyPackageReference:
            return "A Marmot welcome was missing its key package reference."
        case .welcomeRecipientNotFound:
            return "Unable to determine the recipient for a Marmot welcome."
        case .signingKeyUnavailable:
            return "No matching signing key was available for the Marmot welcome."
        case .rumorEncodingFailed:
            return "The Marmot welcome rumor could not be encoded for gift wrapping."
        }
    }
}
