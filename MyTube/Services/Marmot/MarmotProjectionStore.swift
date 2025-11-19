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
        installObserversIfNeeded()
        Task { await refreshAll() }
        
        // Start periodic polling for new messages every 10 seconds
        // This ensures we catch messages even if notifications don't fire
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                await refreshAll()
            }
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        logger.info("🔄 MarmotProjectionStore.refreshAll starting...")
        let groups: [Group]
        do {
            groups = try await mdkActor.getGroups()
            logger.info("   Found \(groups.count) group(s) to refresh")
        } catch {
            logger.error("Failed to load MDK groups: \(error.localizedDescription, privacy: .public)")
            return
        }

        for group in groups {
            logger.info("   Refreshing group: \(group.name) (\(group.mlsGroupId.prefix(16))...)")
            await refreshGroupInternal(groupId: group.mlsGroupId)
        }
        logger.info("✅ MarmotProjectionStore.refreshAll completed")
    }

    func refreshGroup(mlsGroupId: String) async {
        await refreshGroupInternal(groupId: mlsGroupId)
    }

    private func refreshGroupInternal(groupId: String) async {
        logger.debug("      📬 Fetching messages from MDK for group \(groupId.prefix(16))...")
        let messages: [Message]
        do {
            messages = try await mdkActor.getMessages(inGroup: groupId)
            logger.info("      Found \(messages.count) total message(s) in MDK")
        } catch {
            logger.error("Failed to load MDK messages for \(groupId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !messages.isEmpty else { 
            logger.debug("      No messages to process")
            return 
        }
        let lastCursor = lastProcessedByGroup[groupId] ?? 0
        let newMessages = messages
            .filter { $0.processedAt > lastCursor }
            .sorted { $0.processedAt < $1.processedAt }
        logger.info("      Found \(newMessages.count) NEW message(s) to project (cursor: \(lastCursor))")
        guard !newMessages.isEmpty else { return }

        for message in newMessages {
            logger.debug("         Projecting message: \(message.eventId.prefix(16))... state=\(message.state)")
            do {
                try await project(message: message)
                lastProcessedByGroup[groupId] = message.processedAt
                logger.debug("         ✅ Projected successfully")
            } catch {
                logger.error("Projection failed for event \(message.eventId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        persistCursor()
    }

    private func project(message: Message) async throws {
        // Marmot messages are unsigned rumors, so we need to parse the JSON directly
        guard let eventData = message.eventJson.data(using: .utf8),
              let eventObj = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
              let kind = eventObj["kind"] as? UInt16,
              let content = eventObj["content"] as? String else {
            logger.error("Failed to parse Marmot event JSON")
            return
        }

        let processedDate = Date(timeIntervalSince1970: TimeInterval(message.processedAt))
        let kindValue = kind

        guard let messageKind = MarmotMessageKind(rawValue: kindValue) else {
            logger.debug("Ignoring unsupported Marmot message kind \(kindValue)")
            return
        }

        switch messageKind {
        case .follow:
            logger.debug("Received follow message in projection store - handled by ParentZoneViewModel")
            // Follow messages are handled by ParentZoneViewModel.processFollowMessagesInGroup
            // We just log and skip here to avoid duplicate processing
        case .videoShare:
            try projectShare(content: content, processedAt: processedDate)
        case .videoRevoke:
            try projectLifecycle(content: content, status: .revoked, processedAt: processedDate)
        case .videoDelete:
            try projectLifecycle(content: content, status: .deleted, processedAt: processedDate)
        case .like:
            try await projectLike(content: content)
        case .report:
            try await projectReport(content: content, processedAt: processedDate)
        }
    }

    private func installObserversIfNeeded() {
        guard stateObserver == nil, messageObserver == nil else { return }
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

    private func projectShare(content: String, processedAt: Date) throws {
        logger.info("         📹 Projecting video share...")
        guard let metadataJSON = content.data(using: .utf8) else {
            throw ProjectionError.invalidPayload
        }

        let message = try decoder.decode(VideoShareMessage.self, from: metadataJSON)
        logger.info("            Video ID: \(message.videoId)")
        logger.info("            Owner: \(message.ownerChild.prefix(16))...")
        guard let metadataString = String(data: metadataJSON, encoding: .utf8) else {
            throw ProjectionError.invalidPayload
        }
        let model = try remoteVideoStore.upsertRemoteVideoShare(
            message: message,
            metadataJSON: metadataString,
            receivedAt: processedAt
        )
        logger.info("         ✅ Video share projected to RemoteVideoStore: \(model.id)")
    }

    private func projectLifecycle(
        content: String,
        status: RemoteVideoModel.Status,
        processedAt: Date
    ) throws {
        guard let data = content.data(using: .utf8) else {
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

    private func projectLike(content: String) async throws {
        guard let data = content.data(using: .utf8) else {
            throw ProjectionError.invalidPayload
        }
        let message = try decoder.decode(LikeMessage.self, from: data)
        await likeStore.processIncomingLike(message)
    }

    private func projectReport(content: String, processedAt: Date) async throws {
        guard let data = content.data(using: .utf8) else {
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
