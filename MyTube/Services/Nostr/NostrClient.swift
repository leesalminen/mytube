//
//  NostrClient.swift
//  MyTube
//
//  Created by Codex on 12/20/25.
//

import Foundation
import NostrSDK
import OSLog

enum NostrClientError: Error {
    case relayURLInvalid(URL)
    case notConnected([URL])
    case subscriptionFailed
    case publishFailed(Error)
}

@MainActor
protocol NostrClient: AnyObject {
    func connect(relays: [URL]) async throws
    func disconnect() async
    func publish(event: NostrEvent, to relays: [URL]?) async throws
    func subscribe(id: String, filters: [Filter], on relays: [URL]?) async throws
    func unsubscribe(id: String, on relays: [URL]?) async
    func events() -> AsyncStream<NostrEvent>
    func relayStatuses() async -> [RelayHealth]
}

@MainActor
final class RelayPoolNostrClient: NSObject, NostrClient {
    private final class NotificationForwarder: HandleNotification {
        weak var owner: RelayPoolNostrClient?

        init(owner: RelayPoolNostrClient?) {
            self.owner = owner
        }

        func handleMsg(relayUrl: RelayUrl, msg: RelayMessage) async {
            guard let owner else { return }
            await owner.receiveMessage(relayUrl: relayUrl, message: msg)
        }

        func handle(relayUrl: RelayUrl, subscriptionId: String, event: Event) async {
            guard let owner else { return }
            await owner.receiveEvent(relayUrl: relayUrl, subscriptionId: subscriptionId, event: event)
        }
    }

    private let client: Client
    private let notificationHandler: NotificationForwarder
    private var notificationTask: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<NostrEvent>.Continuation] = [:]
    private var statuses: [URL: RelayHealth] = [:]
    private var subscriptions: [String: Set<URL>] = [:]
    private var relayUrlCache: [URL: RelayUrl] = [:]
    private let logger = Logger(subsystem: "com.mytube", category: "NostrClient")

    override init() {
        client = Client()
        notificationHandler = NotificationForwarder(owner: nil)
        super.init()
        notificationHandler.owner = self
        startNotificationLoop()
    }

    deinit {
        notificationTask?.cancel()
    }

    func connect(relays: [URL]) async throws {
        let desired = Set(relays)
        let currentRelays = await client.relays()
        var current: Set<URL> = []
        for (relayUrl, _) in currentRelays {
            if let url = url(from: relayUrl) {
                current.insert(url)
                relayUrlCache[url] = relayUrl
            }
        }

        let toRemove = current.subtracting(desired)
        let toAdd = desired.subtracting(current)

        for url in toRemove {
            if let relayUrl = relayUrlCache[url] {
                do {
                    try await client.removeRelay(url: relayUrl)
                } catch {
                    logger.warning("Failed to remove relay \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            relayUrlCache.removeValue(forKey: url)
            updateHealth(for: url) { health in
                health.status = .disconnected
                health.activeSubscriptions = 0
                health.errorDescription = nil
            }
        }

        for url in toAdd {
            do {
                let relayUrl = try relayUrl(for: url)
                _ = try await client.addRelay(url: relayUrl)
                updateHealth(for: url) { health in
                    health.status = .connecting
                }
            } catch let error as NostrClientError {
                throw error
            } catch {
                logger.error("Invalid relay URL \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw NostrClientError.relayURLInvalid(url)
            }
        }

        await client.connect()
        await refreshStatuses()
    }

    func disconnect() async {
        await client.disconnect()
        notificationTask?.cancel()
        notificationTask = nil
        finishEventStreams()
        for (url, _) in statuses {
            updateHealth(for: url) { health in
                health.status = .disconnected
                health.activeSubscriptions = 0
                health.retryAttempt = 0
                health.nextRetry = nil
            }
        }
        subscriptions.removeAll()
        startNotificationLoop()
    }

    func publish(event: NostrEvent, to relays: [URL]? = nil) async throws {
        do {
            let output: SendEventOutput
            if let relays, !relays.isEmpty {
                let targets = try relays.map(relayUrl(for:))
                output = try await client.sendEventTo(urls: targets, event: event)
            } else {
                output = try await client.sendEvent(event: event)
            }
            handleSendOutput(output)
        } catch {
            logger.error("Failed to publish event \(event.idHex, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw NostrClientError.publishFailed(error)
        }
    }

    func subscribe(id: String, filters: [Filter], on relays: [URL]? = nil) async throws {
        guard !filters.isEmpty else {
            throw NostrClientError.subscriptionFailed
        }

        let relayUrls: [RelayUrl]
        if let relays, !relays.isEmpty {
            relayUrls = try relays.map(relayUrl(for:))
        } else {
            let current = await client.relays()
            relayUrls = Array(current.keys)
            if relayUrls.isEmpty {
                throw NostrClientError.notConnected(relays ?? [])
            }
        }

        var lastError: Error?
        var hadFailure = false

        for filter in filters {
            let message = ClientMessage.req(subscriptionId: id, filter: filter)
            do {
                let output = try await client.sendMsgTo(urls: relayUrls, msg: message)
                handleSubscriptionOutput(output, subscriptionId: id)
                if !output.failed.isEmpty {
                    hadFailure = true
                }
            } catch {
                lastError = error
                hadFailure = true
                logger.error("Subscription \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let error = lastError, subscriptions[id]?.isEmpty ?? true {
            throw error
        }

        if hadFailure && (subscriptions[id]?.isEmpty ?? true) {
            throw NostrClientError.subscriptionFailed
        }
    }

    func unsubscribe(id: String, on relays: [URL]? = nil) async {
        if let relays, !relays.isEmpty {
            let relayUrls = relays.compactMap { try? relayUrl(for: $0) }
            guard !relayUrls.isEmpty else { return }
            let message = ClientMessage.close(subscriptionId: id)
            do {
                let output = try await client.sendMsgTo(urls: relayUrls, msg: message)
                handleUnsubscribeOutput(output, subscriptionId: id)
            } catch {
                logger.error("Failed to close subscription \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            await client.unsubscribe(subscriptionId: id)
            if let urls = subscriptions[id] {
                for url in urls {
                    subscriptions[id]?.remove(url)
                    updateActiveSubscriptions(for: url)
                }
            }
            subscriptions[id] = nil
        }
    }

    func events() -> AsyncStream<NostrEvent> {
        AsyncStream { continuation in
            let token = UUID()
            eventContinuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventContinuations.removeValue(forKey: token)
                }
            }
        }
    }

    func relayStatuses() async -> [RelayHealth] {
        await refreshStatuses()
        return statuses.values.sorted { $0.url.absoluteString < $1.url.absoluteString }
    }

    // MARK: - Notification Loop

    private func startNotificationLoop() {
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.handleNotifications(handler: self.notificationHandler)
            } catch is CancellationError {
                return
            } catch {
                await self.handleNotificationLoopError(error)
            }
        }
    }

    private func handleNotificationLoopError(_ error: Error) async {
        logger.error("Notification loop terminated: \(error.localizedDescription, privacy: .public)")
        startNotificationLoop()
    }

    @MainActor
    private func receiveMessage(relayUrl: RelayUrl, message: RelayMessage) async {
        guard let url = url(from: relayUrl) else { return }
        relayUrlCache[url] = relayUrl
        do {
            let payload = try message.asEnum()
            switch payload {
            case .ok(_, let success, let note):
                if success {
                    updateHealth(for: url) { health in
                        health.status = .connected
                        health.lastSuccess = Date()
                        health.errorDescription = nil
                    }
                } else {
                    updateHealth(for: url) { health in
                        health.status = .error
                        health.lastFailure = Date()
                        health.errorDescription = note
                    }
                }
            case .notice(let info):
                updateHealth(for: url) { health in
                    health.errorDescription = info
                }
            case .closed(_, let reason):
                updateHealth(for: url) { health in
                    health.status = .error
                    health.lastFailure = Date()
                    health.errorDescription = reason
                }
            default:
                break
            }
        } catch {
            logger.error("Failed to decode relay message from \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private func receiveEvent(relayUrl: RelayUrl, subscriptionId: String, event: Event) async {
        guard let url = url(from: relayUrl) else { return }
        relayUrlCache[url] = relayUrl
        updateHealth(for: url) { health in
            health.status = .connected
            health.lastSuccess = Date()
        }
        broadcast(event)
    }

    // MARK: - Helpers

    private func relayUrl(for url: URL) throws -> RelayUrl {
        if let cached = relayUrlCache[url] {
            return cached
        }
        do {
            let parsed = try RelayUrl.parse(url: url.absoluteString)
            relayUrlCache[url] = parsed
            return parsed
        } catch {
            throw NostrClientError.relayURLInvalid(url)
        }
    }

    private func url(from relayUrl: RelayUrl) -> URL? {
        URL(string: relayUrl.description)
    }

    private func refreshStatuses() async {
        let relayMap = await client.relays()
        for (relayUrl, relay) in relayMap {
            guard let url = url(from: relayUrl) else { continue }
            relayUrlCache[url] = relayUrl
            let status = relay.status()
            updateHealth(for: url) { health in
                health.status = mapStatus(status)
            }
        }
    }

    private func mapStatus(_ status: RelayStatus) -> RelayHealth.Status {
        switch status {
        case .connected:
            return .connected
        case .pending, .connecting, .initialized:
            return .connecting
        case .disconnected, .sleeping:
            return .waitingRetry
        case .terminated:
            return .disconnected
        case .banned:
            return .error
        }
    }

    private func handleSendOutput(_ output: SendEventOutput) {
        for relayUrl in output.success {
            guard let url = url(from: relayUrl) else { continue }
            relayUrlCache[url] = relayUrl
            updateHealth(for: url) { health in
                health.status = .connected
                health.lastSuccess = Date()
                health.errorDescription = nil
            }
        }
        for (relayUrl, message) in output.failed {
            guard let url = url(from: relayUrl) else { continue }
            relayUrlCache[url] = relayUrl
            updateHealth(for: url) { health in
                health.status = .error
                health.lastFailure = Date()
                health.errorDescription = message
            }
        }
    }

    private func handleSubscriptionOutput(_ output: Output, subscriptionId: String) {
        let now = Date()
        for relayUrl in output.success {
            guard let url = url(from: relayUrl) else { continue }
            relayUrlCache[url] = relayUrl
            subscriptions[subscriptionId, default: []].insert(url)
            updateHealth(for: url) { health in
                health.status = .connected
                health.lastSuccess = now
                health.errorDescription = nil
            }
            updateActiveSubscriptions(for: url)
        }

        for (relayUrl, message) in output.failed {
            guard let url = url(from: relayUrl) else { continue }
            relayUrlCache[url] = relayUrl
            updateHealth(for: url) { health in
                health.status = .error
                health.lastFailure = Date()
                health.errorDescription = message
            }
            updateActiveSubscriptions(for: url)
        }
    }

    private func handleUnsubscribeOutput(_ output: Output, subscriptionId: String) {
        for relayUrl in output.success {
            guard let url = url(from: relayUrl) else { continue }
            relayUrlCache[url] = relayUrl
            subscriptions[subscriptionId]?.remove(url)
            if subscriptions[subscriptionId]?.isEmpty == true {
                subscriptions[subscriptionId] = nil
            }
            updateActiveSubscriptions(for: url)
        }
    }

    private func broadcast(_ event: NostrEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func finishEventStreams() {
        let continuations = eventContinuations.values
        eventContinuations.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func updateHealth(for url: URL, mutate: (inout RelayHealth) -> Void) {
        var health = statuses[url] ?? RelayHealth(url: url, status: .disconnected)
        mutate(&health)
        statuses[url] = health
    }

    private func updateActiveSubscriptions(for url: URL) {
        let count = subscriptions.values.reduce(0) { partial, urls in
            partial + (urls.contains(url) ? 1 : 0)
        }
        updateHealth(for: url) { health in
            health.activeSubscriptions = count
        }
    }
}

// MARK: - Stub Client (Tests)

@MainActor
final class StubNostrClient: NostrClient {
    private let eventStream: AsyncStream<NostrEvent>
    private let continuation: AsyncStream<NostrEvent>.Continuation
    private var relays: Set<URL> = []

    init(event: NostrEvent? = nil) {
        var continuation: AsyncStream<NostrEvent>.Continuation!
        self.eventStream = AsyncStream { cont in
            continuation = cont
        }
        self.continuation = continuation
        if let event {
            continuation.yield(event)
        }
    }

    func connect(relays: [URL]) async throws {
        self.relays = Set(relays)
    }

    func disconnect() async {
        relays.removeAll()
        continuation.finish()
    }

    func publish(event: NostrEvent, to relays: [URL]?) async throws {
        continuation.yield(event)
    }

    func subscribe(id: String, filters: [Filter], on relays: [URL]?) async throws {
        // No-op for stub.
    }

    func unsubscribe(id: String, on relays: [URL]?) async { }

    func events() -> AsyncStream<NostrEvent> {
        eventStream
    }

    func relayStatuses() async -> [RelayHealth] {
        relays.map { RelayHealth(url: $0, status: .connected) }
    }
}
