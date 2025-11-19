//
//  TestRelayInfrastructure.swift
//  MyTubeTests
//
//  Created by Assistant on 11/18/25.
//

import Foundation
import NostrSDK
@testable import MyTube

/// A lightweight in-memory relay that broadcasts every published event to all registered clients.
actor TestRelay {
    private struct Client {
        var relays: [URL]
        let continuation: AsyncStream<NostrEvent>.Continuation
    }

    private var clients: [UUID: Client] = [:]
    private let defaultRelay = URL(string: "wss://no.str.cr")!

    func register(clientID: UUID, continuation: AsyncStream<NostrEvent>.Continuation) {
        clients[clientID] = Client(relays: [defaultRelay], continuation: continuation)
    }

    func connect(clientID: UUID, relays: [URL]) {
        guard var client = clients[clientID] else { return }
        client.relays = relays.isEmpty ? [defaultRelay] : relays
        clients[clientID] = client
    }

    func disconnect(clientID: UUID) {
        guard let client = clients.removeValue(forKey: clientID) else { return }
        client.continuation.finish()
    }

    func publish(event: NostrEvent, from sender: UUID) {
        for client in clients.values {
            client.continuation.yield(event)
        }
    }

    func statuses(for clientID: UUID) -> [RelayHealth] {
        guard let relays = clients[clientID]?.relays, !relays.isEmpty else {
            return [RelayHealth(url: defaultRelay, status: .connected)]
        }
        return relays.map { RelayHealth(url: $0, status: .connected) }
    }
}

/// Nostr client implementation wired into the in-memory `TestRelay`.
@MainActor
final class IntegratedNostrClient: NostrClient {
    private let relay: TestRelay
    private let id = UUID()
    private var registered = false
    private let eventStream: AsyncStream<NostrEvent>
    private let continuation: AsyncStream<NostrEvent>.Continuation

    init(relay: TestRelay) {
        self.relay = relay
        var captured: AsyncStream<NostrEvent>.Continuation!
        self.eventStream = AsyncStream { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    private func ensureRegistration() async {
        guard !registered else { return }
        await relay.register(clientID: id, continuation: continuation)
        registered = true
    }

    func connect(relays: [URL]) async throws {
        await ensureRegistration()
        await relay.connect(clientID: id, relays: relays)
    }

    func disconnect() async {
        guard registered else { return }
        await relay.disconnect(clientID: id)
        registered = false
    }

    func publish(event: NostrEvent, to relays: [URL]?) async throws {
        await ensureRegistration()
        await relay.publish(event: event, from: id)
    }

    func subscribe(id: String, filters: [Filter], on relays: [URL]?) async throws {
        await ensureRegistration()
        // Filters are ignored for the in-memory relay; all events are broadcast to everyone.
    }

    func unsubscribe(id: String, on relays: [URL]?) async {
        // No-op for the in-memory relay
    }

    func events() -> AsyncStream<NostrEvent> {
        eventStream
    }

    func relayStatuses() async -> [RelayHealth] {
        await relay.statuses(for: id)
    }
}

