//
//  MarmotProjectionStoreTests.swift
//  MyTubeTests
//
//  Created by Assistant on 03/05/26.
//

import XCTest
import NostrSDK
@testable import MyTube
import MDKBindings

final class MarmotProjectionStoreTests: XCTestCase {
    func testRefreshProjectsShareLikeReportAndLifecycle() async throws {
        let persistence = PersistenceController(inMemory: true)
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarmotProjectionStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let storagePaths = try StoragePaths(baseURL: tempRoot)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let remoteVideoStore = RemoteVideoStore(persistence: persistence)
        let childProfileStore = ChildProfileStore(persistence: persistence)
        let likeStore: LikeStore = await MainActor.run {
            LikeStore(
                persistenceController: persistence,
                childProfileStore: childProfileStore
            )
        }
        let reportStore: ReportStore = await MainActor.run {
            ReportStore(persistence: persistence)
        }
        let defaultsSuite = "MarmotProjectionStoreTests.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let stubMdk = StubMessageQueryClient()
        let groupId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let group = Group(
            mlsGroupId: groupId,
            nostrGroupId: String(repeating: "0", count: 64),
            name: "Test Group",
            description: "Test",
            imageHash: nil,
            imageKey: nil,
            imageNonce: nil,
            adminPubkeys: [],
            lastMessageId: nil,
            lastMessageAt: nil,
            epoch: 1,
            state: "active"
        )
        await stubMdk.setGroups([group])

        let videoId = UUID()
        let shareMessage = makeShareMessage(videoId: videoId)
        let shareEvent = try makeEvent(kind: MarmotMessageKind.videoShare.rawValue, content: encode(shareMessage))
        let likeMessage = LikeMessage(
            videoId: videoId.uuidString,
            viewerChild: "npub1viewer",
            by: "npub1parentviewer",
            timestamp: Date()
        )
        let likeEvent = try makeEvent(kind: MarmotMessageKind.like.rawValue, content: encode(likeMessage))
        let reportMessage = ReportMessage(
            videoId: videoId.uuidString,
            subjectChild: "npub1subject",
            reason: "spam",
            note: "bad content",
            by: "npub1parent",
            timestamp: Date()
        )
        let reportEvent = try makeEvent(kind: MarmotMessageKind.report.rawValue, content: encode(reportMessage))
        let lifecycleMessage = VideoLifecycleMessage(
            kind: .videoRevoke,
            videoId: videoId.uuidString,
            reason: "parent_removed",
            by: "npub1parent",
            timestamp: Date()
        )
        let lifecycleEvent = try makeEvent(kind: MarmotMessageKind.videoRevoke.rawValue, content: encode(lifecycleMessage))

        let baseTimestamp = UInt64(Date().timeIntervalSince1970)
        await stubMdk.setMessages([
            groupId: [
                Message(
                    id: shareEvent.idHex,
                    mlsGroupId: groupId,
                    nostrGroupId: group.nostrGroupId,
                    eventId: shareEvent.idHex,
                    eventJson: try shareEvent.asJson(),
                    processedAt: baseTimestamp,
                    state: "processed"
                ),
                Message(
                    id: likeEvent.idHex,
                    mlsGroupId: groupId,
                    nostrGroupId: group.nostrGroupId,
                    eventId: likeEvent.idHex,
                    eventJson: try likeEvent.asJson(),
                    processedAt: baseTimestamp + 1,
                    state: "processed"
                ),
                Message(
                    id: reportEvent.idHex,
                    mlsGroupId: groupId,
                    nostrGroupId: group.nostrGroupId,
                    eventId: reportEvent.idHex,
                    eventJson: try reportEvent.asJson(),
                    processedAt: baseTimestamp + 2,
                    state: "processed"
                ),
                Message(
                    id: lifecycleEvent.idHex,
                    mlsGroupId: groupId,
                    nostrGroupId: group.nostrGroupId,
                    eventId: lifecycleEvent.idHex,
                    eventJson: try lifecycleEvent.asJson(),
                    processedAt: baseTimestamp + 3,
                    state: "processed"
                )
            ]
        ])

        let store = MarmotProjectionStore(
            mdkActor: stubMdk,
            remoteVideoStore: remoteVideoStore,
            likeStore: likeStore,
            reportStore: reportStore,
            storagePaths: storagePaths,
            notificationCenter: NotificationCenter(),
            userDefaults: defaults
        )

        await store.refreshAll()

        let videos = try remoteVideoStore.fetchAllVideos()
        XCTAssertEqual(videos.count, 1)
        let storedVideo = try XCTUnwrap(videos.first)
        XCTAssertEqual(storedVideo.id, videoId.uuidString)
        XCTAssertEqual(storedVideo.ownerChild, shareMessage.ownerChild)
        XCTAssertEqual(storedVideo.statusValue, .revoked)

        let likeCount = await MainActor.run {
            likeStore.likeCount(for: videoId)
        }
        XCTAssertEqual(likeCount, 1)

        let reports = await MainActor.run {
            reportStore.allReports()
        }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.videoId, videoId.uuidString)
    }

    func testMessageNotificationTriggersIncrementalRefresh() async throws {
        let persistence = PersistenceController(inMemory: true)
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarmotProjectionStoreTests-Incremental-\(UUID().uuidString)",
            isDirectory: true
        )
        let storagePaths = try StoragePaths(baseURL: tempRoot)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let remoteVideoStore = RemoteVideoStore(persistence: persistence)
        let childProfileStore = ChildProfileStore(persistence: persistence)
        let likeStore: LikeStore = await MainActor.run {
            LikeStore(
                persistenceController: persistence,
                childProfileStore: childProfileStore
            )
        }
        let reportStore: ReportStore = await MainActor.run {
            ReportStore(persistence: persistence)
        }

        let defaultsSuite = "MarmotProjectionStoreTests.incremental.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let notificationCenter = NotificationCenter()
        let stubMdk = StubMessageQueryClient()
        let groupId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let group = Group(
            mlsGroupId: groupId,
            nostrGroupId: String(repeating: "0", count: 64),
            name: "Incremental Group",
            description: "Incremental",
            imageHash: nil,
            imageKey: nil,
            imageNonce: nil,
            adminPubkeys: [],
            lastMessageId: nil,
            lastMessageAt: nil,
            epoch: 1,
            state: "active"
        )
        await stubMdk.setGroups([group])

        let videoId = UUID()
        let shareMessage = makeShareMessage(videoId: videoId)
        let shareEvent = try makeEvent(
            kind: MarmotMessageKind.videoShare.rawValue,
            content: encode(shareMessage)
        )
        let baseTimestamp = UInt64(Date().timeIntervalSince1970)
        await stubMdk.setMessages([
            groupId: [
                Message(
                    id: shareEvent.idHex,
                    mlsGroupId: groupId,
                    nostrGroupId: group.nostrGroupId,
                    eventId: shareEvent.idHex,
                    eventJson: try shareEvent.asJson(),
                    processedAt: baseTimestamp,
                    state: "processed"
                )
            ]
        ])

        let store = MarmotProjectionStore(
            mdkActor: stubMdk,
            remoteVideoStore: remoteVideoStore,
            likeStore: likeStore,
            reportStore: reportStore,
            storagePaths: storagePaths,
            notificationCenter: notificationCenter,
            userDefaults: defaults
        )

        await store.refreshAll()
        var likeCount = await MainActor.run {
            likeStore.likeCount(for: videoId)
        }
        XCTAssertEqual(likeCount, 0)

        let likeMessage = LikeMessage(
            videoId: videoId.uuidString,
            viewerChild: "npub1viewer",
            by: "npub1parentviewer",
            timestamp: Date()
        )
        let likeEvent = try makeEvent(
            kind: MarmotMessageKind.like.rawValue,
            content: encode(likeMessage)
        )
        await stubMdk.setMessages([
            groupId: [
                Message(
                    id: shareEvent.idHex,
                    mlsGroupId: groupId,
                    nostrGroupId: group.nostrGroupId,
                    eventId: shareEvent.idHex,
                    eventJson: try shareEvent.asJson(),
                    processedAt: baseTimestamp,
                    state: "processed"
                ),
                Message(
                    id: likeEvent.idHex,
                    mlsGroupId: groupId,
                    nostrGroupId: group.nostrGroupId,
                    eventId: likeEvent.idHex,
                    eventJson: try likeEvent.asJson(),
                    processedAt: baseTimestamp + 1,
                    state: "processed"
                )
            ]
        ])

        let expectation = expectation(description: "Like processed")
        let monitorTask = Task {
            while await MainActor.run { likeStore.likeCount(for: videoId) } == 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            expectation.fulfill()
        }

        notificationCenter.post(
            name: .marmotMessagesDidChange,
            object: nil,
            userInfo: ["mlsGroupId": groupId]
        )

        await fulfillment(of: [expectation], timeout: 2.0)
        monitorTask.cancel()

        likeCount = await MainActor.run {
            likeStore.likeCount(for: videoId)
        }
        XCTAssertEqual(likeCount, 1)
    }

    // MARK: - Helpers

    private func makeShareMessage(videoId: UUID) -> VideoShareMessage {
        VideoShareMessage(
            videoId: videoId.uuidString,
            ownerChild: "npub1ownerchild",
            meta: VideoShareMessage.Meta(
                title: "Campfire",
                duration: 42,
                createdAt: Date()
            ),
            blob: VideoShareMessage.Blob(
                url: "https://example.com/video.mp4",
                mime: "video/mp4",
                length: 1024,
                key: "video.mp4"
            ),
            thumb: VideoShareMessage.Blob(
                url: "https://example.com/thumb.jpg",
                mime: "image/jpeg",
                length: 128,
                key: "thumb.jpg"
            ),
            crypto: VideoShareMessage.Crypto(
                algMedia: "xchacha20poly1305",
                nonceMedia: "nonce",
                mediaKey: "key"
            ),
            policy: VideoShareMessage.Policy(visibility: "followers", expiresAt: nil, version: 1),
            by: "npub1parentowner",
            timestamp: Date()
        )
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(value)
        return String(data: data, encoding: .utf8)!
    }

    private func makeEvent(kind: UInt16, content: String) throws -> NostrEvent {
        let builder = EventBuilder(kind: Kind(kind: kind), content: content)
        let pair = try NostrKeyPair(secretKey: SecretKey.generate())
        return try builder.signWithKeys(keys: pair.makeKeys())
    }
}

private actor StubMessageQueryClient: MarmotMessageQuerying {
    var groups: [Group] = []
    var messagesByGroup: [String: [Message]] = [:]

    func setGroups(_ groups: [Group]) {
        self.groups = groups
    }

    func setMessages(_ messages: [String: [Message]]) {
        self.messagesByGroup = messages
    }

    func getGroups() throws -> [Group] {
        groups
    }

    func getMessages(inGroup mlsGroupId: String) throws -> [Message] {
        messagesByGroup[mlsGroupId] ?? []
    }
}
