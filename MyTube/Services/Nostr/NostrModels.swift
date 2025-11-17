//
//  NostrModels.swift
//  MyTube
//
//  Created by Codex on 12/20/25.
//

import Foundation
import NostrSDK

typealias NostrEvent = NostrSDK.Event
typealias EventKind = NostrSDK.Kind

enum MyTubeEventKind: Int {
    case metadata = 0
    case childFollowPointer = 30301
    case videoTombstone = 30302
}

extension EventKind {
    static var metadata: EventKind { EventKind(kind: UInt16(MyTubeEventKind.metadata.rawValue)) }
    static var mytubeChildFollowPointer: EventKind { EventKind(kind: UInt16(MyTubeEventKind.childFollowPointer.rawValue)) }
    static var mytubeVideoTombstone: EventKind { EventKind(kind: UInt16(MyTubeEventKind.videoTombstone.rawValue)) }
}

/// Snapshot describing the connection health of a relay.
struct RelayHealth: Identifiable, Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case connecting
        case connected
        case waitingRetry
        case disconnected
        case error
    }

    var url: URL
    var status: Status
    var retryAttempt: Int
    var lastSuccess: Date?
    var lastFailure: Date?
    var nextRetry: Date?
    var errorDescription: String?
    var activeSubscriptions: Int
    var consecutiveFailures: Int
    var roundTripLatency: TimeInterval?

    var id: String { url.absoluteString }

    init(
        url: URL,
        status: Status = .connecting,
        retryAttempt: Int = 0,
        lastSuccess: Date? = nil,
        lastFailure: Date? = nil,
        nextRetry: Date? = nil,
        errorDescription: String? = nil,
        activeSubscriptions: Int = 0,
        consecutiveFailures: Int = 0,
        roundTripLatency: TimeInterval? = nil
    ) {
        self.url = url
        self.status = status
        self.retryAttempt = retryAttempt
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.nextRetry = nextRetry
        self.errorDescription = errorDescription
        self.activeSubscriptions = activeSubscriptions
        self.consecutiveFailures = consecutiveFailures
        self.roundTripLatency = roundTripLatency
    }
}

extension NostrEvent {
    var idHex: String {
        (try? id().toHex()) ?? (try? id().toBech32()) ?? ""
    }

    var pubkey: String {
        author().toHex()
    }

    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt().asSecs()))
    }

    /// Returns the first tag value matching the provided tag name (case-insensitive).
    func tagValue(for name: String) -> String? {
        let lowercased = name.lowercased()
        for tag in tags().toVec() {
            if tag.kindStr().lowercased() == lowercased {
                let components = tag.asVec()
                if components.count > 1 {
                    return components[1]
                }
            }
        }
        return nil
    }

    /// Exposes tags in the raw string array format expected by existing persistence helpers.
    var rawTags: [[String]] {
        tags().toVec().map { $0.asVec() }
    }
}

extension Tag {
    var name: String {
        kindStr()
    }

    var value: String {
        let components = asVec()
        return components.count > 1 ? components[1] : ""
    }

    var otherParameters: [String] {
        let components = asVec()
        guard components.count > 2 else { return [] }
        return Array(components.dropFirst(2))
    }
}

enum NostrTagBuilder {
    static func make(name: String, value: String, otherParameters: [String] = []) -> Tag {
        let payload = [name, value] + otherParameters
        do {
            return try Tag.parse(data: payload)
        } catch {
            preconditionFailure("Failed to encode tag \(payload): \(error)")
        }
    }
}
