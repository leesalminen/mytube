//
//  NostrModels.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import Foundation

/// Canonical representation of a Nostr event used across the app.
/// Docs: https://github.com/nostr-protocol/nips/blob/master/01.md
struct NostrEvent: Identifiable, Codable, Sendable {
    typealias Tag = [String]

    /// Hex-encoded event id (SHA-256 hash of serialized payload).
    let id: String
    /// Hex-encoded public key of the event author.
    let pubkey: String
    /// Unix timestamp (seconds).
    let createdAt: Int
    /// Event kind (e.g., 30300 for family link replaceables).
    let kind: Int
    /// Array of Nostr tags. Each tag is `[key, value, ...]`.
    let tags: [Tag]
    /// Raw content (UTF-8 text or JSON string depending on kind).
    let content: String
    /// Schnorr signature over the event hash.
    let sig: String

    enum CodingKeys: String, CodingKey {
        case id
        case pubkey
        case createdAt = "created_at"
        case kind
        case tags
        case content
        case sig
    }
}

/// Wrapper for establishing subscriptions against relays.
struct NostrSubscription: Hashable, Codable, Sendable {
    let id: String
    var filters: [NostrFilter]

    init(id: String = UUID().uuidString, filters: [NostrFilter]) {
        self.id = id
        self.filters = filters
    }
}

/// Simplified filter model. Extend as needed for complex queries.
struct NostrFilter: Hashable, Codable, Sendable {
    var kinds: [Int] = []
    var authors: [String] = []
    var ids: [String] = []
    var referencedEventIds: [String] = []
    var referencedPubkeys: [String] = []
    var since: Int?
    var until: Int?
    var limit: Int?

    enum CodingKeys: String, CodingKey {
        case kinds
        case authors
        case ids
        case referencedEventIds = "#e"
        case referencedPubkeys = "#p"
        case since
        case until
        case limit
    }

    var dictionaryRepresentation: [String: Any] {
        var dict: [String: Any] = [:]
        if !kinds.isEmpty { dict["kinds"] = kinds }
        if !authors.isEmpty { dict["authors"] = authors }
        if !ids.isEmpty { dict["ids"] = ids }
        if !referencedEventIds.isEmpty { dict["#e"] = referencedEventIds }
        if !referencedPubkeys.isEmpty { dict["#p"] = referencedPubkeys }
        if let since { dict["since"] = since }
        if let until { dict["until"] = until }
        if let limit { dict["limit"] = limit }
        return dict
    }
}

/// High-level type groupings used by MyTube on top of base kinds.
enum MyTubeEventKind: Int {
    case familyLinkPointer = 30300
    case childFollowPointer = 30301
    case videoTombstone = 30302
    case directMessage = 14
}

/// Snapshot describing the connection health of a relay.
struct RelayHealth: Identifiable, Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case connecting
        case connected
        case waitingRetry
        case disconnected
    }

    var url: URL
    var status: Status
    var retryAttempt: Int
    var lastSuccess: Date?
    var lastFailure: Date?
    var nextRetry: Date?
    var errorDescription: String?
    var activeSubscriptions: Int

    var id: String { url.absoluteString }

    init(url: URL,
         status: Status = .connecting,
         retryAttempt: Int = 0,
         lastSuccess: Date? = nil,
         lastFailure: Date? = nil,
         nextRetry: Date? = nil,
         errorDescription: String? = nil,
         activeSubscriptions: Int = 0) {
        self.url = url
        self.status = status
        self.retryAttempt = retryAttempt
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.nextRetry = nextRetry
        self.errorDescription = errorDescription
        self.activeSubscriptions = activeSubscriptions
    }
}

extension NostrEvent {
    func tagValue(for key: String) -> String? {
        guard let tag = tags.first(where: { $0.first?.lowercased() == key.lowercased() }) else {
            return nil
        }
        return tag.dropFirst().first
    }

    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }
}
