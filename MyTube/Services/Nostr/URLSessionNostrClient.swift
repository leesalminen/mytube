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

    private struct RetryState {
        var attempt: Int = 0
        var task: Task<Void, Never>?
        var nextRetry: Date?
        var errorDescription: String?
    }

    private struct StoredSubscription {
        var model: NostrSubscription
        var targetRelays: Set<URL>?
    }

    private var connections: [URL: RelayConnection] = [:]
    private var desiredRelays: Set<URL> = []
    private var subscriptions: [String: StoredSubscription] = [:]
    private var eventContinuations: [UUID: AsyncStream<NostrEvent>.Continuation] = [:]
    private var retryStates: [URL: RetryState] = [:]
    private var healthByURL: [URL: RelayHealth] = [:]
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
        desiredRelays = target
        let existing = Set(connections.keys)

        let toRemove = existing.subtracting(target)
        for url in toRemove {
            await closeConnection(for: url)
            await clearRetry(for: url)
            updateHealth(for: url) { health in
                health.status = .disconnected
                health.retryAttempt = 0
                health.nextRetry = nil
                health.errorDescription = nil
                health.activeSubscriptions = 0
            }
        }

        let toAdd = target.subtracting(existing)
        for url in toAdd {
            updateHealth(for: url) { health in
                health.status = .connecting
                health.retryAttempt = 0
                health.errorDescription = nil
            }
            do {
                try await openConnection(to: url)
            } catch {
                logger.error("Failed to open relay \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await handleConnectionFailure(for: url, error: error)
            }
        }

        // Ensure any desired relay without a live connection has a scheduled reconnect.
        for url in target where connections[url] == nil {
            guard retryStates[url] == nil else { continue }
            scheduleReconnect(for: url, afterFailure: nil)
        }
    }

    func disconnect() async {
        desiredRelays.removeAll()
        for url in connections.keys {
            await closeConnection(for: url)
        }
        for url in retryStates.keys {
            await clearRetry(for: url)
            updateHealth(for: url) { health in
                health.status = .disconnected
                health.retryAttempt = 0
                health.nextRetry = nil
                health.errorDescription = nil
                health.activeSubscriptions = 0
            }
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

        subscriptions[subscription.id] = StoredSubscription(model: subscription,
                                                            targetRelays: relays.map { Set($0) })
        let message = try buildSubscribeMessage(subscription)
        for connection in targets {
            connection.subscriptions.insert(subscription.id)
            do {
                try await send(message, over: connection)
            } catch {
                connection.subscriptions.remove(subscription.id)
                await handleConnectionFailure(for: connection.url, error: error)
            }
            updateHealth(for: connection.url) { health in
                health.activeSubscriptions = connection.subscriptions.count
            }
        }
    }

    func unsubscribe(id: String, on relays: [URL]? = nil) async {
        guard let message = try? buildUnsubscribeMessage(id: id) else { return }
        let targets = (try? targetConnections(relays)) ?? []
        for connection in targets {
            connection.subscriptions.remove(id)
            do {
                try await send(message, over: connection)
            } catch {
                await handleConnectionFailure(for: connection.url, error: error)
            }
            updateHealth(for: connection.url) { health in
                health.activeSubscriptions = connection.subscriptions.count
            }
        }

        if relays == nil {
            subscriptions.removeValue(forKey: id)
        } else if var stored = subscriptions[id] {
            var target = stored.targetRelays ?? desiredRelays
            for url in relays ?? [] {
                target.remove(url)
            }
            stored.targetRelays = target
            if target.isEmpty {
                subscriptions.removeValue(forKey: id)
            } else {
                subscriptions[id] = stored
            }
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

        await clearRetry(for: url)
        task.resume()
        connection.listener = Task { [weak self] in
            guard let self else { return }
            await self.readLoop(for: url)
        }
        updateHealth(for: url) { health in
            health.status = .connected
            health.retryAttempt = 0
            health.nextRetry = nil
            health.errorDescription = nil
            health.lastSuccess = Date()
            health.activeSubscriptions = connection.subscriptions.count
        }
        logger.debug("Opened Nostr relay connection: \(url.absoluteString, privacy: .public)")
        await resubscribe(on: connection)
    }

    private func closeConnection(for url: URL) async {
        guard let connection = connections[url] else { return }
        connection.listener?.cancel()
        connection.task.cancel(with: .goingAway, reason: nil)
        connections.removeValue(forKey: url)
        updateHealth(for: url) { health in
            health.status = .disconnected
            health.activeSubscriptions = 0
        }
        logger.debug("Closed Nostr relay connection: \(url.absoluteString, privacy: .public)")
    }

    private func readLoop(for url: URL) async {
        while let connection = connections[url] {
            do {
                let message = try await connection.task.receive()
                await handle(message: message, from: url)
            } catch is CancellationError {
                return
            } catch {
                logger.error("Relay receive failure (\(url.absoluteString, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                await handleConnectionFailure(for: url, error: error)
                return
            }
        }
    }

    // MARK: - Health & Retry

    private func handleConnectionFailure(for url: URL, error: Error) async {
        if (error as? CancellationError) != nil {
            return
        }

        logger.error("Handling relay failure (\(url.absoluteString, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        await closeConnection(for: url)
        scheduleReconnect(for: url, afterFailure: error)
    }

    private func scheduleReconnect(for url: URL, afterFailure error: Error?) {
        guard desiredRelays.contains(url) else { return }

        var state = retryStates[url] ?? RetryState()
        state.attempt += 1

        let delaySeconds = min(pow(2.0, Double(state.attempt - 1)), 60)
        let nextRetry = Date().addingTimeInterval(delaySeconds)
        state.nextRetry = nextRetry
        if let error {
            state.errorDescription = (error as NSError).localizedDescription
        } else if state.attempt == 1 {
            state.errorDescription = nil
        }
        state.task?.cancel()
        state.task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            await self.attemptReconnect(url: url)
        }
        retryStates[url] = state

        updateHealth(for: url) { health in
            health.status = .waitingRetry
            health.retryAttempt = state.attempt
            health.nextRetry = nextRetry
            health.errorDescription = state.errorDescription
            if error != nil {
                health.lastFailure = Date()
            }
            health.activeSubscriptions = 0
        }
    }

    private func attemptReconnect(url: URL) async {
        guard desiredRelays.contains(url) else { return }
        do {
            try await openConnection(to: url)
        } catch {
            await handleConnectionFailure(for: url, error: error)
        }
    }

    private func clearRetry(for url: URL) async {
        guard let state = retryStates[url] else { return }
        state.task?.cancel()
        retryStates.removeValue(forKey: url)
        updateHealth(for: url) { health in
            health.retryAttempt = 0
            health.nextRetry = nil
        }
    }

    private func resubscribe(on connection: RelayConnection) async {
        guard !subscriptions.isEmpty else {
            updateHealth(for: connection.url) { health in
                health.activeSubscriptions = connection.subscriptions.count
            }
            return
        }

        for stored in subscriptions.values {
            if let targets = stored.targetRelays, !targets.contains(connection.url) {
                continue
            }

            do {
                let message = try buildSubscribeMessage(stored.model)
                connection.subscriptions.insert(stored.model.id)
                try await send(message, over: connection)
                updateHealth(for: connection.url) { health in
                    health.activeSubscriptions = connection.subscriptions.count
                }
            } catch {
                connection.subscriptions.remove(stored.model.id)
                logger.error("Failed to resubscribe \(stored.model.id, privacy: .public) on \(connection.url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await handleConnectionFailure(for: connection.url, error: error)
                return
            }
        }
    }

    private func updateHealth(for url: URL, mutation: (inout RelayHealth) -> Void) {
        var health = healthByURL[url] ?? RelayHealth(url: url, status: .disconnected)
        mutation(&health)
        healthByURL[url] = health
    }

    // MARK: - Message Handling

    private func handle(message: URLSessionWebSocketTask.Message, from url: URL) async {
        switch message {
        case let .string(text):
            await processRawSegments(text, from: url)
        case let .data(data):
            if let text = String(data: data, encoding: .utf8) {
                await processRawSegments(text, from: url)
            } else {
                logger.warning("Received non-UTF8 data from relay \(url.absoluteString, privacy: .public)")
            }
        @unknown default:
            logger.warning("Received unknown message type from relay \(url.absoluteString, privacy: .public)")
        }
    }

    private func processRawSegments(_ text: String, from url: URL) async {
        let segments = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        if segments.isEmpty {
            await processRawMessage(text, from: url)
        } else {
            for segment in segments {
                await processRawMessage(segment, from: url)
            }
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
            logger.error("Failed to parse relay message: \(error.localizedDescription, privacy: .public) payload: \(text, privacy: .public)")
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

    func relayStatuses() async -> [RelayHealth] {
        healthByURL.values.sorted { $0.url.absoluteString < $1.url.absoluteString }
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
