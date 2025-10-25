//
//  ParentZoneViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Foundation

@MainActor
final class ParentZoneViewModel: ObservableObject {
    @Published var isUnlocked = false
    @Published var pinEntry = ""
    @Published var newPin = ""
    @Published var confirmPin = ""
    @Published var errorMessage: String?
    @Published var videos: [VideoModel] = []
    @Published var storageUsage: StorageUsage = .empty
    @Published var calmModeEnabled: Bool

    private let environment: AppEnvironment
    private let parentAuth: ParentAuth

    init(environment: AppEnvironment) {
        self.environment = environment
        self.parentAuth = environment.parentAuth
        self.calmModeEnabled = environment.calmModeEnabled
    }

    var needsSetup: Bool {
        !parentAuth.isPinConfigured()
    }

    func authenticate() {
        do {
            if parentAuth.isPinConfigured() {
                guard try parentAuth.validate(pin: pinEntry) else {
                    errorMessage = "Incorrect PIN"
                    return
                }
                unlock()
            } else {
                guard newPin == confirmPin, newPin.count >= 4 else {
                    errorMessage = "PINs must match and be 4+ digits"
                    return
                }
                try parentAuth.configure(pin: newPin)
                unlock()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlockWithBiometrics() {
        Task {
            do {
                try await parentAuth.evaluateBiometric(reason: "Unlock Parent Zone")
                unlock()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleCalmMode(_ enabled: Bool) {
        calmModeEnabled = enabled
        environment.setCalmMode(enabled: enabled)
    }

    func refreshVideos() {
        do {
            videos = try environment.videoLibrary.fetchVideos(profileId: environment.activeProfile.id, includeHidden: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func storageBreakdown() {
        let root = environment.storagePaths.rootURL
        let media = totalSize(at: root.appendingPathComponent(StoragePaths.Directory.media.rawValue))
        let thumbs = totalSize(at: root.appendingPathComponent(StoragePaths.Directory.thumbs.rawValue))
        let edits = totalSize(at: root.appendingPathComponent(StoragePaths.Directory.edits.rawValue))
        storageUsage = StorageUsage(media: media, thumbs: thumbs, edits: edits)
    }

    func toggleVisibility(for video: VideoModel) {
        Task {
            do {
                let updated = try await environment.videoLibrary.toggleHidden(videoId: video.id, isHidden: !video.hidden)
                updateCache(with: updated)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(video: VideoModel) {
        Task {
            do {
                try await environment.videoLibrary.deleteVideo(videoId: video.id)
                videos.removeAll { $0.id == video.id }
            } catch {
                errorMessage = error.localizedDescription
            }
            storageBreakdown()
        }
    }

    func shareURL(for video: VideoModel) -> URL {
        environment.videoLibrary.videoFileURL(for: video)
    }

    private func unlock() {
        isUnlocked = true
        pinEntry = ""
        newPin = ""
        confirmPin = ""
        errorMessage = nil
        refreshVideos()
        storageBreakdown()
    }

    private func updateCache(with video: VideoModel) {
        if let index = videos.firstIndex(where: { $0.id == video.id }) {
            videos[index] = video
        } else {
            videos.append(video)
        }
    }

    private func totalSize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    struct StorageUsage {
        let media: Int64
        let thumbs: Int64
        let edits: Int64

        static let empty = StorageUsage(media: 0, thumbs: 0, edits: 0)

        var total: Int64 { media + thumbs + edits }
    }
}
