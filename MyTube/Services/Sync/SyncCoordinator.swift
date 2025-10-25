//
//  SyncCoordinator.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import Foundation
import OSLog

actor SyncCoordinator {
    private enum State {
        case idle
        case running
    }

    private let nostrClient: NostrClient
    private let relayDirectory: RelayDirectory
    private let eventReducer: NostrEventReducer
    private var eventTask: Task<Void, Never>?
    private var state: State = .idle
    private let logger = Logger(subsystem: "com.mytube", category: "SyncCoordinator")

    init(persistence: PersistenceController, nostrClient: NostrClient, relayDirectory: RelayDirectory) {
        self.nostrClient = nostrClient
        self.relayDirectory = relayDirectory
        self.eventReducer = NostrEventReducer(context: SyncReducerContext(persistence: persistence))
    }

    func start() async {
        guard state == .idle else { return }
        state = .running

        do {
            let relays = await relayDirectory.currentRelayURLs()
            if !relays.isEmpty {
                try await nostrClient.connect(relays: relays)
            }
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
        } catch {
            logger.error("Relay refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        state = .idle
        await nostrClient.disconnect()
    }

    private func consumeEvents() async {
        for await event in nostrClient.events() {
            await handle(event)
        }
        logger.info("Event stream completed.")
        state = .idle
    }

    private func handle(_ event: NostrEvent) async {
        logger.debug("Received event kind \(event.kind, privacy: .public) id \(event.id, privacy: .public)")
        await eventReducer.handle(event: event)
    }
}
