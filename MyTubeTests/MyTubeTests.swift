//
//  MyTubeTests.swift
//  MyTubeTests
//
//  Created by Lee Salminen on 10/24/25.
//

import CoreData
import Foundation
import Testing
@testable import MyTube

struct MyTubeTests {

    @Test("Ranking engine prioritizes liked videos")
    func rankingEnginePrefersLikedVideos() async throws {
        let profileID = UUID()
        let videos = [
            VideoModel(
                id: UUID(),
                profileId: profileID,
                filePath: "video1.mp4",
                thumbPath: "thumb1.jpg",
                title: "Chalk Rockets",
                duration: 30,
                createdAt: Date(),
                lastPlayedAt: nil,
                playCount: 2,
                completionRate: 0.6,
                replayRate: 0.1,
                liked: false,
                hidden: false,
                tags: ["art"],
                cvLabels: [],
                faceCount: 1,
                loudness: 0.3
            ),
            VideoModel(
                id: UUID(),
                profileId: profileID,
                filePath: "video2.mp4",
                thumbPath: "thumb2.jpg",
                title: "Dance Party",
                duration: 40,
                createdAt: Date().addingTimeInterval(-3600),
                lastPlayedAt: nil,
                playCount: 1,
                completionRate: 0.8,
                replayRate: 0.2,
                liked: true,
                hidden: false,
                tags: ["music"],
                cvLabels: [],
                faceCount: 2,
                loudness: 0.5
            )
        ]

        let rankingState = RankingStateModel(profileId: profileID, topicSuccess: ["music": 0.9], exploreRate: 0.15)
        let result = RankingEngine().rank(videos: videos, rankingState: rankingState)

        #expect(result.hero?.video.title == "Dance Party")
    }

    @Test("Video library persists video metadata")
    func videoLibraryPersistsVideo() async throws {
        let persistence = PersistenceController(inMemory: true)
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent("MyTubeTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let storage = try StoragePaths(baseURL: tempBase)
        let library = VideoLibrary(persistence: persistence, storagePaths: storage)

        let profileID = UUID()
        let profile = ProfileEntity(context: persistence.viewContext)
        profile.id = profileID
        profile.name = "Test Child"
        profile.theme = ThemeDescriptor.ocean.rawValue
        profile.avatarAsset = "avatar.dolphin"
        try persistence.viewContext.save()

        let tempVideo = tempBase.appendingPathComponent("source.mp4")
        let tempThumb = tempBase.appendingPathComponent("source.jpg")
        FileManager.default.createFile(atPath: tempVideo.path, contents: Data(repeating: 0, count: 1024 * 10))
        FileManager.default.createFile(atPath: tempThumb.path, contents: Data(repeating: 0, count: 512))

        let request = VideoCreationRequest(
            profileId: profileID,
            sourceURL: tempVideo,
            thumbnailURL: tempThumb,
            title: "Test Clip",
            duration: 5,
            tags: [],
            cvLabels: [],
            faceCount: 0,
            loudness: 0.2
        )

        let video = try await library.createVideo(request: request)

        #expect(video.title == "Test Clip")
        let fetched = try persistence.viewContext.fetch(VideoEntity.fetchRequest())
        #expect(fetched.count == 1)
    }
}
