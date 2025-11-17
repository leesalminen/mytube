//
//  MarmotProjectionStore.swift
//  MyTube
//
//  Created by Assistant on 03/05/26.
//

import Foundation
import MDKBindings
import NostrSDK
import OSLog

actor MarmotProjectionStore {
    private enum Constants {
        static let cursorDefaultsKey = "MarmotProjectionStore.lastProcessed"
    }

    private enum NotificationKeys {
        static let groupId = "mlsGroupId"
    }

    private let mdkActor: any MarmotMessageQuerying
    private let remoteVideoStore: RemoteVideoStore
    private let likeStore: LikeStore
    private let reportStore: ReportStore
    private let storagePaths: StoragePaths
    private let notificationCenter: NotificationCenter
    private let userDefaults: UserDefaults
    private let logger = Logger(subsystem: "com.mytube", category: "MarmotProjectionStore")
    private let decoder: JSONDecoder
    private var lastProcessedByGroup: [String: UInt64]
    private var stateObserver: NSObjectProtocol?
    private var messageObserver: NSObjectProtocol?
    private var isRefreshing = false

    init(
        mdkActor: any MarmotMessageQuerying,
        remoteVideoStore: RemoteVideoStore,
        likeStore: LikeStore,
        reportStore: ReportStore,
        storagePaths: StoragePaths,
        notificationCenter: NotificationCenter = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.mdkActor = mdkActor
        self.remoteVideoStore = remoteVideoStore
        self.likeStore = likeStore
        self.reportStore = reportStore
        self.storagePaths = storagePaths
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder

        self.lastProcessedByGroup = Self.loadCursor(from: userDefaults)

        stateObserver = notificationCenter.addObserver(
            forName: .marmotStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.refreshAll() }
        }

        messageObserver = notificationCenter.addObserver(
            forName: .marmotMessagesDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let groupId = notification.userInfo?[NotificationKeys.groupId] as? String else { return }
            Task { await self?.refreshGroup(mlsGroupId: groupId) }
        }
    }

    deinit {
        if let stateObserver {
            notificationCenter.removeObserver(stateObserver)
        }
        if let messageObserver {
            notificationCenter.removeObserver(messageObserver)
        }
    }

    func start() {
        Task {
            await refreshAll()
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let groups: [Group]
        do {
            groups = try await mdkActor.getGroups()
        } catch {
            logger.error("Failed to load MDK groups: \(error.localizedDescription, privacy: .public)")
            return
        }

        for group in groups {
            await refreshGroupInternal(groupId: group.mlsGroupId)
        }
    }

    func refreshGroup(mlsGroupId: String) async {
        await refreshGroupInternal(groupId: mlsGroupId)
    }

    private func refreshGroupInternal(groupId: String) async {
        let messages: [Message]
        do {
            messages = try await mdkActor.getMessages(inGroup: groupId)
        } catch {
            logger.error("Failed to load MDK messages for \(groupId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !messages.isEmpty else { return }
        let lastCursor = lastProcessedByGroup[groupId] ?? 0
        let newMessages = messages
            .filter { $0.processedAt > lastCursor }
            .sorted { $0.processedAt < $1.processedAt }
        guard !newMessages.isEmpty else { return }

        for message in newMessages {
            do {
                try await project(message: message)
                lastProcessedByGroup[groupId] = message.processedAt
            } catch {
                logger.error("Projection failed for event \(message.eventId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        persistCursor()
    }

    private func project(message: Message) async throws {
        let event: NostrEvent
        do {
            event = try NostrEvent.fromJson(json: message.eventJson)
        } catch {
            logger.error("Failed to decode Marmot event JSON: \(error.localizedDescription, privacy: .public)")
            return
        }

        let processedDate = Date(timeIntervalSince1970: TimeInterval(message.processedAt))
        let kindValue = event.kind().asU16()

        guard let messageKind = MarmotMessageKind(rawValue: kindValue) else {
            logger.debug("Ignoring unsupported Marmot message kind \(kindValue)")
            return
        }

        switch messageKind {
        case .videoShare:
            try projectShare(event: event, processedAt: processedDate)
        case .videoRevoke:
            try projectLifecycle(event: event, status: .revoked, processedAt: processedDate)
        case .videoDelete:
            try projectLifecycle(event: event, status: .deleted, processedAt: processedDate)
        case .like:
            try await projectLike(event: event)
        case .report:
            try await projectReport(event: event, processedAt: processedDate)
        }
    }

    private func projectShare(event: NostrEvent, processedAt: Date) throws {
        guard let metadataJSON = event.content().data(using: .utf8) else {
            throw ProjectionError.invalidPayload
        }

        let message = try decoder.decode(VideoShareMessage.self, from: metadataJSON)
        guard let metadataString = String(data: metadataJSON, encoding: .utf8) else {
            throw ProjectionError.invalidPayload
        }
        _ = try remoteVideoStore.upsertRemoteVideoShare(
            message: message,
            metadataJSON: metadataString,
            receivedAt: processedAt
        )
    }

    private func projectLifecycle(
        event: NostrEvent,
        status: RemoteVideoModel.Status,
        processedAt: Date
    ) throws {
        guard let data = event.content().data(using: .utf8) else {
            throw ProjectionError.invalidPayload
        }
        let message = try decoder.decode(VideoLifecycleMessage.self, from: data)
        _ = try remoteVideoStore.applyLifecycleEvent(
            videoId: message.videoId,
            status: status,
            reason: message.reason,
            storagePaths: storagePaths,
            timestamp: processedAt
        )
    }

    private func projectLike(event: NostrEvent) async throws {
        guard let data = event.content().data(using: .utf8) else {
            throw ProjectionError.invalidPayload
        }
        let message = try decoder.decode(LikeMessage.self, from: data)
        await likeStore.processIncomingLike(message)
    }

    private func projectReport(event: NostrEvent, processedAt: Date) async throws {
        guard let data = event.content().data(using: .utf8) else {
            throw ProjectionError.invalidPayload
        }
        let message = try decoder.decode(ReportMessage.self, from: data)
        let createdAt = Date(timeIntervalSince1970: message.ts)
        _ = try await reportStore.ingestReportMessage(
            message,
            isOutbound: false,
            createdAt: createdAt,
            deliveredAt: processedAt,
            defaultStatus: .pending,
            action: .none
        )
    }

    private func persistCursor() {
        let payload = lastProcessedByGroup.mapValues { NSNumber(value: $0) }
        userDefaults.set(payload, forKey: Constants.cursorDefaultsKey)
    }

    private static func loadCursor(from defaults: UserDefaults) -> [String: UInt64] {
        guard let stored = defaults.dictionary(forKey: Constants.cursorDefaultsKey) else {
            return [:]
        }
        var result: [String: UInt64] = [:]
        for (key, value) in stored {
            if let number = value as? NSNumber {
                result[key] = number.uint64Value
            }
        }
        return result
    }

    enum ProjectionError: Error {
        case invalidPayload
    }
}
