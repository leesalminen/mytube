//
//  NostrClient.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import Foundation

enum NostrClientError: Error {
    case relayURLInvalid
    case connectionClosed
    case writeFailed
    case subscriptionFailed
    case decodeFailed
    case notConnected
}

/// Defines the contract for relay interactions. A concrete implementation will manage WebSocket connections,
/// outgoing commands, and event dispatch.
protocol NostrClient: AnyObject {
    func connect(relays: [URL]) async throws
    func disconnect() async
    func publish(event: NostrEvent, to relays: [URL]?) async throws
    func subscribe(_ subscription: NostrSubscription, on relays: [URL]?) async throws
    func unsubscribe(id: String, on relays: [URL]?) async
    func events() -> AsyncStream<NostrEvent>
}

/// Placeholder implementation that records relay configuration but does not yet open sockets.
/// The real networking stack will replace this with a WebSocket-driven implementation.
final class StubNostrClient: NostrClient {
    private let eventStream: AsyncStream<NostrEvent>
    private let continuation: AsyncStream<NostrEvent>.Continuation
    private var connectedRelays: [URL] = []
    private let queue = DispatchQueue(label: "com.mytube.nostr.stub", qos: .utility)

    init() {
        var continuation: AsyncStream<NostrEvent>.Continuation!
        let stream = AsyncStream(NostrEvent.self) { cont in
            continuation = cont
        }
        eventStream = stream
        self.continuation = continuation
    }

    func connect(relays: [URL]) async throws {
        connectedRelays = relays
    }

    func disconnect() async {
        connectedRelays.removeAll()
        continuation.finish()
    }

    func publish(event: NostrEvent, to relays: [URL]? = nil) async throws {
        let targets = relays ?? connectedRelays
        guard !targets.isEmpty else {
            throw NostrClientError.notConnected
        }
        queue.async { [continuation] in
            continuation.yield(event)
        }
    }

    func subscribe(_ subscription: NostrSubscription, on relays: [URL]? = nil) async throws {
        guard !(relays ?? connectedRelays).isEmpty else {
            throw NostrClientError.notConnected
        }
        // No-op in stub.
    }

    func unsubscribe(id: String, on relays: [URL]? = nil) async {
        // No-op stub.
    }

    func events() -> AsyncStream<NostrEvent> {
        eventStream
    }
}
