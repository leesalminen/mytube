//
//  URLSessionNostrClient.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import Foundation
import OSLog

actor URLSessionNostrClient: NostrClient {
    private final class RelayConnection {
        let url: URL
        let task: URLSessionWebSocketTask
        var listener: Task<Void, Never>?
        var subscriptions: Set<String> = []

        init(url: URL, task: URLSessionWebSocketTask) {
            self.url = url
            self.task = task
        }
    }

    private var connections: [URL: RelayConnection] = [:]
    private var eventContinuations: [UUID: AsyncStream<NostrEvent>.Continuation] = [:]
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    private let logger = Logger(subsystem: "com.mytube", category: "NostrClient")

    init(configuration: URLSessionConfiguration = .default) {
        var config = configuration
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config)
    }

    func connect(relays: [URL]) async throws {
        let target = Set(relays)
        let existing = Set(connections.keys)

        let toRemove = existing.subtracting(target)
        for url in toRemove {
            await closeConnection(for: url)
        }

        let toAdd = target.subtracting(existing)
        for url in toAdd {
            try await openConnection(to: url)
        }
    }

    func disconnect() async {
        for url in connections.keys {
            await closeConnection(for: url)
        }
        finishEventStreams()
    }

    func publish(event: NostrEvent, to relays: [URL]? = nil) async throws {
        let targets = try targetConnections(relays)
        let message = try buildEventMessage(event)

        for connection in targets {
            try await send(message, over: connection)
        }
    }

    func subscribe(_ subscription: NostrSubscription, on relays: [URL]? = nil) async throws {
        let targets = try targetConnections(relays)
        guard !subscription.filters.isEmpty else {
            throw NostrClientError.subscriptionFailed
        }

        let message = try buildSubscribeMessage(subscription)
        for connection in targets {
            connection.subscriptions.insert(subscription.id)
            try await send(message, over: connection)
        }
    }

    func unsubscribe(id: String, on relays: [URL]? = nil) async {
        guard let message = try? buildUnsubscribeMessage(id: id) else { return }
        let targets = (try? targetConnections(relays)) ?? []
        for connection in targets {
            connection.subscriptions.remove(id)
            try? await send(message, over: connection)
        }
    }

    // MARK: - Connection Lifecycle

    private func openConnection(to url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            throw NostrClientError.relayURLInvalid
        }
        let task = session.webSocketTask(with: url)
        let connection = RelayConnection(url: url, task: task)
        connections[url] = connection

        task.resume()
        connection.listener = Task { [weak self] in
            guard let self else { return }
            await self.readLoop(for: url)
        }
        logger.debug("Opened Nostr relay connection: \(url.absoluteString, privacy: .public)")
    }

    private func closeConnection(for url: URL) async {
        guard let connection = connections[url] else { return }
        connection.listener?.cancel()
        connection.task.cancel(with: .goingAway, reason: nil)
        connections.removeValue(forKey: url)
        logger.debug("Closed Nostr relay connection: \(url.absoluteString, privacy: .public)")
    }

    private func readLoop(for url: URL) async {
        while let connection = connections[url] {
            do {
                let message = try await connection.task.receive()
                await handle(message: message, from: url)
            } catch {
                logger.error("Relay receive failure (\(url.absoluteString, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                break
            }
        }

        await closeConnection(for: url)
    }

    // MARK: - Message Handling

    private func handle(message: URLSessionWebSocketTask.Message, from url: URL) async {
        switch message {
        case let .string(text):
            await processRawMessage(text, from: url)
        case let .data(data):
            if let text = String(data: data, encoding: .utf8) {
                await processRawMessage(text, from: url)
            } else {
                logger.warning("Received non-UTF8 data from relay \(url.absoluteString, privacy: .public)")
            }
        @unknown default:
            logger.warning("Received unknown message type from relay \(url.absoluteString, privacy: .public)")
        }
    }

    private func processRawMessage(_ text: String, from url: URL) async {
        guard let data = text.data(using: .utf8) else {
            logger.error("Failed to encode relay payload as UTF8.")
            return
        }

        do {
            let raw = try JSONSerialization.jsonObject(with: data) as? [Any]
            guard let kind = raw?.first as? String else { return }

            switch kind {
            case "EVENT":
                if let eventPayload = raw?.dropFirst(2).first {
                    try await handleEventPayload(eventPayload)
                }
            case "NOTICE":
                if let notice = raw?.dropFirst().first as? String {
                    logger.info("Relay notice (\(url.absoluteString, privacy: .public)): \(notice, privacy: .public)")
                }
            case "EOSE":
                break
            default:
                break
            }
        } catch {
            logger.error("Failed to parse relay message: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleEventPayload(_ payload: Any) async throws {
        guard let dictionary = payload as? [String: Any] else { return }
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        let event = try decoder.decode(NostrEvent.self, from: data)
        broadcast(event)
    }

    // MARK: - Message Builders

    private func buildEventMessage(_ event: NostrEvent) throws -> [Any] {
        let eventDict = try dictionary(from: event)
        return ["EVENT", eventDict]
    }

    private func buildSubscribeMessage(_ subscription: NostrSubscription) throws -> [Any] {
        var components: [Any] = ["REQ", subscription.id]
        components.append(contentsOf: subscription.filters.map(\.dictionaryRepresentation))
        return components
    }

    private func buildUnsubscribeMessage(id: String) throws -> [Any] {
        ["CLOSE", id]
    }

    private func dictionary(from event: NostrEvent) throws -> [String: Any] {
        let data = try encoder.encode(event)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NostrClientError.decodeFailed
        }
        return object
    }

    // MARK: - Utilities

    private func send(_ message: [Any], over connection: RelayConnection) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NostrClientError.writeFailed
        }
        try await send(string: string, over: connection.task)
    }

    private func send(string: String, over task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.string(string)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func targetConnections(_ relays: [URL]?) throws -> [RelayConnection] {
        if let relays {
            let targets = relays.compactMap { connections[$0] }
            guard !targets.isEmpty else { throw NostrClientError.notConnected }
            return targets
        }
        let values = Array(connections.values)
        guard !values.isEmpty else { throw NostrClientError.notConnected }
        return values
    }

    private func broadcast(_ event: NostrEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func addContinuation(_ continuation: AsyncStream<NostrEvent>.Continuation, token: UUID) {
        eventContinuations[token] = continuation
    }

    private func removeContinuation(_ token: UUID) {
        eventContinuations.removeValue(forKey: token)
    }

    private func finishEventStreams() {
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }
}

extension URLSessionNostrClient {
    nonisolated func events() -> AsyncStream<NostrEvent> {
        AsyncStream { continuation in
            let token = UUID()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
            Task { [weak self] in
                guard let self else { return }
                await self.addContinuation(continuation, token: token)
            }
        }
    }
}
