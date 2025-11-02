//
//  SyncCoordinator.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import Foundation
import OSLog
import NostrSDK

actor SyncCoordinator {
    private enum State {
        case idle
        case running
    }

    private let nostrClient: NostrClient
    private let relayDirectory: RelayDirectory
    private let eventReducer: NostrEventReducer
    private let keyStore: KeychainKeyStore
    private let relationshipStore: RelationshipStore
    private let parentProfileStore: ParentProfileStore
    private let childProfileStore: ChildProfileStore
    private var eventTask: Task<Void, Never>?
    private var state: State = .idle
    private let logger = Logger(subsystem: "com.mytube", category: "SyncCoordinator")
    private var primarySubscriptionId: String?
    private var trackedKeySnapshot: Set<String> = []
    private var trackedParentKey: String?
    private let subscriptionToken = "mytube.primary.sync"

    init(
        persistence: PersistenceController,
        nostrClient: NostrClient,
        relayDirectory: RelayDirectory,
        keyStore: KeychainKeyStore,
        cryptoService: CryptoEnvelopeService,
        relationshipStore: RelationshipStore,
        parentProfileStore: ParentProfileStore,
        childProfileStore: ChildProfileStore,
        likeStore: LikeStore,
        reportStore: ReportStore,
        remoteVideoStore: RemoteVideoStore,
        videoLibrary: VideoLibrary,
        storagePaths: StoragePaths
    ) {
        self.nostrClient = nostrClient
        self.relayDirectory = relayDirectory
        self.keyStore = keyStore
        self.relationshipStore = relationshipStore
        self.parentProfileStore = parentProfileStore
        self.childProfileStore = childProfileStore
        self.eventReducer = NostrEventReducer(
            context: SyncReducerContext(
                persistence: persistence,
                keyStore: keyStore,
                cryptoService: cryptoService,
                relationshipStore: relationshipStore,
                parentProfileStore: parentProfileStore,
                childProfileStore: childProfileStore,
                likeStore: likeStore,
                reportStore: reportStore,
                remoteVideoStore: remoteVideoStore,
                videoLibrary: videoLibrary,
                storagePaths: storagePaths
            )
        )
    }

    func start() async {
        guard state == .idle else { return }
        state = .running

        do {
            let relays = await relayDirectory.currentRelayURLs()
            if !relays.isEmpty {
                try await nostrClient.connect(relays: relays)
            }
            await ensurePrimarySubscription(force: true)
        } catch {
            logger.error("Failed to connect to relays: \(error.localizedDescription, privacy: .public)")
        }

        eventTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeEvents()
        }
    }

    func refreshRelays() async {
        let relays = await relayDirectory.currentRelayURLs()
        do {
            try await nostrClient.connect(relays: relays)
            await ensurePrimarySubscription(force: true)
        } catch {
            logger.error("Relay refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        state = .idle
        if let subscriptionId = primarySubscriptionId {
            await nostrClient.unsubscribe(id: subscriptionId, on: nil)
        }
        primarySubscriptionId = nil
        trackedKeySnapshot.removeAll()
        trackedParentKey = nil
        await nostrClient.disconnect()
    }

    func relayStatuses() async -> [RelayHealth] {
        return await nostrClient.relayStatuses()
    }

    func refreshSubscriptions() async {
        await ensurePrimarySubscription(force: true)
    }

    private func consumeEvents() async {
        let stream = await nostrClient.events()
        for await event in stream {
            await handle(event)
        }
        logger.info("Event stream completed.")
        state = .idle
    }

    private func handle(_ event: NostrEvent) async {
        let kindCode = event.kind().asU16()
        logger.debug("Received event kind \(kindCode, privacy: .public) id \(event.idHex, privacy: .public)")
        await eventReducer.handle(event: event)
    }

    private func ensurePrimarySubscription(force: Bool = false) async {
        guard state == .running else { return }

        let snapshot = await gatherTrackedKeys()
        let parentHex = snapshot.parent
        var pointerKeys = snapshot.childKeys
        pointerKeys.formUnion(snapshot.remoteParentKeys)
        if let parentHex { pointerKeys.insert(parentHex) }

        let sinceSeconds = Date().addingTimeInterval(-14 * 24 * 60 * 60).timeIntervalSince1970
        let sinceTimestamp = Timestamp.fromSecs(secs: UInt64(max(0, Int(sinceSeconds))))
        let dmKinds = [Kind(kind: UInt16(MyTubeEventKind.directMessage.rawValue))]
        var filters: [Filter] = []

        if !pointerKeys.isEmpty {
            let pubkeys = pointerKeys.compactMap { try? NostrSDK.PublicKey.parse(publicKey: $0) }
            if !pubkeys.isEmpty {
                let kinds = [
                    Kind(kind: UInt16(MyTubeEventKind.childFollowPointer.rawValue)),
                    Kind(kind: UInt16(MyTubeEventKind.videoTombstone.rawValue))
                ]
                var filter = Filter()
                filter = filter.kinds(kinds: kinds)
                filter = filter.pubkeys(pubkeys: pubkeys)
                filter = filter.authors(authors: pubkeys)
                filter = filter.since(timestamp: sinceTimestamp)
                filters.append(filter)
            }
        }

        var metadataKeySet = snapshot.remoteParentKeys
        metadataKeySet.formUnion(snapshot.childKeys)
        if let parentHex {
            metadataKeySet.insert(parentHex)
        }
        let metadataAuthors = metadataKeySet.compactMap { try? NostrSDK.PublicKey.parse(publicKey: $0) }
        if !metadataAuthors.isEmpty {
            var metadataFilter = Filter()
            metadataFilter = metadataFilter.kinds(kinds: [Kind(kind: UInt16(MyTubeEventKind.metadata.rawValue))])
            metadataFilter = metadataFilter.authors(authors: metadataAuthors)
            metadataFilter = metadataFilter.since(timestamp: sinceTimestamp)
            filters.append(metadataFilter)
        }

        if let parentHex {
            let normalizedParent = parentHex.lowercased()
            guard let parentKey = try? NostrSDK.PublicKey.parse(publicKey: normalizedParent) else {
                logger.warning("Unable to parse parent public key for subscriptions")
                return
            }

            // Inbound direct messages address our parent key via the #p tag.
            var inboundDMFilter = Filter()
            inboundDMFilter = inboundDMFilter.kinds(kinds: dmKinds)
            inboundDMFilter = inboundDMFilter.pubkeys(pubkeys: [parentKey])
            inboundDMFilter = inboundDMFilter.since(timestamp: sinceTimestamp)
            filters.append(inboundDMFilter)

            // Outbound messages still need to be tracked so reducers can reconcile state.
            var outboundDMFilter = Filter()
            outboundDMFilter = outboundDMFilter.kinds(kinds: dmKinds)
            outboundDMFilter = outboundDMFilter.authors(authors: [parentKey])
            outboundDMFilter = outboundDMFilter.since(timestamp: sinceTimestamp)
            filters.append(outboundDMFilter)
        }

        if filters.isEmpty {
            if let subscriptionId = primarySubscriptionId {
                await nostrClient.unsubscribe(id: subscriptionId, on: nil)
            }
            primarySubscriptionId = nil
            trackedKeySnapshot = pointerKeys
            trackedParentKey = parentHex
            return
        }

        if !force,
           pointerKeys == trackedKeySnapshot,
           parentHex == trackedParentKey,
           primarySubscriptionId != nil {
            return
        }

        do {
            if let subscriptionId = primarySubscriptionId {
                await nostrClient.unsubscribe(id: subscriptionId, on: nil)
            }
            try await nostrClient.subscribe(id: subscriptionToken, filters: filters, on: nil)
            primarySubscriptionId = subscriptionToken
            trackedParentKey = parentHex
            trackedKeySnapshot = pointerKeys
            logger.debug("Subscribed to primary nostr feeds with \(filters.count) filters")
        } catch {
            logger.error("Failed to subscribe to primary feeds: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func gatherTrackedKeys() async -> (parent: String?, childKeys: Set<String>, remoteParentKeys: Set<String>) {
        var parentHex: String?
        if let parentPair = try? keyStore.fetchKeyPair(role: .parent) {
            parentHex = parentPair.publicKeyHex.lowercased()
        }

        var childKeys: Set<String> = []
        if let identifiers = try? keyStore.childKeyIdentifiers() {
            for id in identifiers {
                if let pair = try? keyStore.fetchKeyPair(role: .child(id: id)) {
                    childKeys.insert(pair.publicKeyHex.lowercased())
                }
            }
        }

        let snapshot = await relationshipStore.followKeySnapshot()
        childKeys.formUnion(snapshot.childKeys)

        let remoteParents: Set<String>
        if let parent = parentHex {
            remoteParents = Set(
                snapshot.parentKeys.filter {
                    $0.caseInsensitiveCompare(parent) != ComparisonResult.orderedSame
                }
            )
        } else {
            remoteParents = snapshot.parentKeys
        }

        return (parentHex, childKeys, remoteParents)
    }
}
