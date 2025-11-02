//
//  VideoSharePublisher.swift
//  MyTube
//
//  Created by Codex on 10/26/25.
//

import Foundation
import OSLog
import NostrSDK

struct VideoShareOptions {
    var visibility: String

    static let `default` = VideoShareOptions(visibility: "followers")
}

enum VideoSharePublisherError: Error {
    case fileMissing(URL)
    case thumbnailMissing(URL)
    case invalidRecipientKey
}

actor VideoSharePublisher {
    private struct StagedUpload: Sendable {
        let mediaKey: Data
        let encryptedPayload: EncryptedMediaPayload
        let videoBlob: VideoShareMessage.Blob
        let thumbBlob: VideoShareMessage.Blob
    }

    private let storagePaths: StoragePaths
    private let cryptoService: CryptoEnvelopeService
    private let storageClient: any MediaStorageClient
    private let directMessageOutbox: any DirectMessageSending
    private let keyStore: KeychainKeyStore
    private let parentProfileStore: ParentProfileStore
    private let logger = Logger(subsystem: "com.mytube", category: "VideoSharePublisher")
    private var stagedUploads: [UUID: Task<StagedUpload, Error>] = [:]

    init(
        storagePaths: StoragePaths,
        cryptoService: CryptoEnvelopeService,
        storageClient: any MediaStorageClient,
        directMessageOutbox: any DirectMessageSending,
        keyStore: KeychainKeyStore,
        parentProfileStore: ParentProfileStore
    ) {
        self.storagePaths = storagePaths
        self.cryptoService = cryptoService
        self.storageClient = storageClient
        self.directMessageOutbox = directMessageOutbox
        self.keyStore = keyStore
        self.parentProfileStore = parentProfileStore
    }

    @discardableResult
    func share(
        video: VideoModel,
        ownerChildNpub: String,
        recipientPublicKey: String,
        options: VideoShareOptions = .default
    ) async throws -> VideoShareMessage {
        let stage = try await stageUpload(video: video, ownerChildNpub: ownerChildNpub)
        let recipient = try resolveRecipientKey(recipientPublicKey)
        let recipientWrapKey = await fetchRecipientWrapKey(hex: recipient.hex)
        let parentKeyPair = try keyStore.ensureParentKeyPair()
        let now = Date()

        let crypto: VideoShareMessage.Crypto
        if let wrapKey = recipientWrapKey, wrapKey.count == 32 {
            let wrappedKey = try cryptoService.wrapMediaKey(stage.mediaKey, for: wrapKey)
            crypto = VideoShareMessage.Crypto(
                algMedia: cryptoService.mediaAlgorithmIdentifier,
                nonceMedia: stage.encryptedPayload.nonce.base64EncodedString(),
                mediaKey: nil,
                algWrap: cryptoService.wrapAlgorithmIdentifier,
                wrap: VideoShareMessage.Crypto.Wrap(
                    ephemeralPub: wrappedKey.ephemeralPublicKey.base64EncodedString(),
                    wrapSalt: wrappedKey.wrapSalt.base64EncodedString(),
                    wrapNonce: wrappedKey.wrapNonce.base64EncodedString(),
                    keyWrapped: wrappedKey.keyCiphertext.base64EncodedString()
                )
            )
        } else {
            if recipientWrapKey == nil {
                logger.debug("No wrap key for recipient \(recipient.hex.prefix(8))… falling back to direct media key.")
            } else {
                logger.warning("Wrap key for recipient \(recipient.hex.prefix(8))… invalid length; expected 32 bytes.")
            }
            crypto = VideoShareMessage.Crypto(
                algMedia: cryptoService.mediaAlgorithmIdentifier,
                nonceMedia: stage.encryptedPayload.nonce.base64EncodedString(),
                mediaKey: stage.mediaKey.base64EncodedString()
            )
        }

        let policy = VideoShareMessage.Policy(
            visibility: options.visibility,
            expiresAt: nil,
            version: 1
        )

        let meta = VideoShareMessage.Meta(
            title: video.title,
            duration: video.duration,
            createdAt: video.createdAt
        )

        let message = VideoShareMessage(
            videoId: video.id.uuidString,
            ownerChild: ownerChildNpub,
            meta: meta,
            blob: stage.videoBlob,
            thumb: stage.thumbBlob,
            crypto: crypto,
            policy: policy,
            by: parentKeyPair.publicKeyHex,
            timestamp: now
        )

        try await directMessageOutbox.sendMessage(
            message,
            kind: .videoShare,
            recipientPublicKey: recipient.hex,
            additionalTags: [NostrTagBuilder.make(name: "d", value: video.id.uuidString)],
            relayOverride: nil,
            createdAt: now
        )

        logger.info("Shared video \(video.id.uuidString, privacy: .public) with recipient \(recipient.hex.prefix(8))…")
        return message
    }

    private func mimeType(forExtension ext: String, defaultType: String) -> String {
        switch ext.lowercased() {
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "m4v":
            return "video/x-m4v"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        default:
            return defaultType
        }
    }

    private func fetchRecipientWrapKey(hex: String) async -> Data? {
        await MainActor.run {
            do {
                return try parentProfileStore.profile(for: hex.lowercased())?.wrapPublicKey
            } catch {
                logger.error("Failed to load wrap key for \(hex.prefix(8))… \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    private func resolveRecipientKey(_ input: String) throws -> (hex: String, data: Data) {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw VideoSharePublisherError.invalidRecipientKey }

        let lowercase = cleaned.lowercased()
        if let hexData = Data(hexString: lowercase), hexData.count == 32 {
            return (hexData.hexEncodedString(), hexData)
        }

        if lowercase.hasPrefix(NIP19Kind.npub.rawValue) {
            let decoded = try NIP19.decode(lowercase)
            guard decoded.kind == .npub else {
                throw VideoSharePublisherError.invalidRecipientKey
            }
            return (decoded.data.hexEncodedString(), decoded.data)
        }

        throw VideoSharePublisherError.invalidRecipientKey
    }

    private func sanitizeComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        let lowercased = value.lowercased()
        let scalars = lowercased.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars)
    }

    private func stageUpload(video: VideoModel, ownerChildNpub: String) async throws -> StagedUpload {
        if let existing = stagedUploads[video.id] {
            return try await existing.value
        }

        let task = Task<StagedUpload, Error> {
            let videoURL = storagePaths.rootURL.appendingPathComponent(video.filePath)
            let thumbURL = storagePaths.rootURL.appendingPathComponent(video.thumbPath)

            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                throw VideoSharePublisherError.fileMissing(videoURL)
            }
            guard FileManager.default.fileExists(atPath: thumbURL.path) else {
                throw VideoSharePublisherError.thumbnailMissing(thumbURL)
            }

            let videoData = try Data(contentsOf: videoURL, options: .mappedIfSafe)
            let thumbData = try Data(contentsOf: thumbURL, options: .mappedIfSafe)

            let mediaKey = try cryptoService.generateMediaKey()
            let encryptedPayload = try cryptoService.encryptMedia(videoData, key: mediaKey)
            let encryptedVideoData = encryptedPayload.combined()

            let keyPrefix = [
                "videos",
                sanitizeComponent(ownerChildNpub),
                video.id.uuidString.lowercased()
            ].joined(separator: "/")

            let encryptedResult = try await storageClient.uploadObject(
                data: encryptedVideoData,
                contentType: "application/octet-stream",
                suggestedKey: "\(keyPrefix)/media.bin"
            )

            let thumbContentType = mimeType(forExtension: thumbURL.pathExtension, defaultType: "image/jpeg")
            let thumbExtension = thumbURL.pathExtension.isEmpty ? "jpg" : thumbURL.pathExtension.lowercased()
            let thumbResult = try await storageClient.uploadObject(
                data: thumbData,
                contentType: thumbContentType,
                suggestedKey: "\(keyPrefix)/thumb.\(thumbExtension)"
            )

            let videoObjectURL: URL
            if let downloadURL = encryptedResult.accessURL {
                videoObjectURL = downloadURL
            } else {
                videoObjectURL = try await storageClient.objectURL(for: encryptedResult.key)
            }

            let thumbObjectURL: URL
            if let downloadURL = thumbResult.accessURL {
                thumbObjectURL = downloadURL
            } else {
                thumbObjectURL = try await storageClient.objectURL(for: thumbResult.key)
            }
            let videoMime = mimeType(forExtension: videoURL.pathExtension, defaultType: "video/mp4")

            let blob = VideoShareMessage.Blob(
                url: videoObjectURL.absoluteString,
                mime: videoMime,
                length: encryptedVideoData.count,
                key: encryptedResult.key
            )

            let thumbBlob = VideoShareMessage.Blob(
                url: thumbObjectURL.absoluteString,
                mime: thumbContentType,
                length: thumbData.count,
                key: thumbResult.key
            )

            return StagedUpload(
                mediaKey: mediaKey,
                encryptedPayload: encryptedPayload,
                videoBlob: blob,
                thumbBlob: thumbBlob
            )
        }

        stagedUploads[video.id] = task
        do {
            let value = try await task.value
            return value
        } catch {
            stagedUploads[video.id] = nil
            throw error
        }
    }
}

extension VideoSharePublisherError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .fileMissing(let url):
            return "Video file is missing at \(url.lastPathComponent)."
        case .thumbnailMissing(let url):
            return "Thumbnail is missing at \(url.lastPathComponent)."
        case .invalidRecipientKey:
            return "Recipient key must be a hex string or npub."
        }
    }
}
