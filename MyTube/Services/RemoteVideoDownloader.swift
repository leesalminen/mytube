//
//  RemoteVideoDownloader.swift
//  MyTube
//
//  Created by Codex on 11/13/25.
//

import CoreData
import Foundation
import OSLog

actor RemoteVideoDownloader {
    enum DownloadError: Error, LocalizedError, Sendable {
        case videoRecordMissing
        case metadataCorrupted
        case parentIdentityMissing
        case invalidEnvelope
        case invalidNonce
        case unsupportedMediaAlgorithm(String)
        case mediaDownloadFailed(URL)
        case thumbDownloadFailed(URL)
        case mediaDecryptionFailed
        case storageFailed(String)
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .videoRecordMissing:
                return "This shared video is no longer available."
            case .metadataCorrupted:
                return "We couldn’t read the shared video details."
            case .invalidEnvelope:
                return "This share was created with an older format and can’t be decrypted. Ask the sender to resend after updating MyTube."
            case .parentIdentityMissing:
                return "A parent identity is required on this device to decrypt shared videos."
            case .invalidNonce:
                return "The encrypted video payload is invalid."
            case .unsupportedMediaAlgorithm(let algorithm):
                return "The shared video uses an unsupported encryption algorithm (\(algorithm))."
            case .mediaDownloadFailed(let url):
                return "We couldn’t download the video from \(url.host ?? url.absoluteString)."
            case .thumbDownloadFailed(let url):
                return "We couldn’t download the preview image from \(url.host ?? url.absoluteString)."
            case .mediaDecryptionFailed:
                return "Decrypting the shared video failed."
            case .storageFailed(let reason):
                return "Saving the video failed: \(reason)."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    private struct DownloadInput: Sendable {
        let videoId: String
        let message: VideoShareMessage
        let blobURL: URL?
        let thumbURL: URL?
        let blobKey: String?
        let thumbKey: String?
        let previousMediaPath: String?
        let previousThumbPath: String?
    }

    private let persistence: PersistenceController
    private let storagePaths: StoragePaths
    private let keyStore: KeychainKeyStore
    private let cryptoService: CryptoEnvelopeService
    private let storageClient: any MediaStorageClient
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.mytube", category: "RemoteVideoDownloader")
    private var inFlight: [String: Task<RemoteVideoModel, Error>] = [:]
    private let jsonDecoder: JSONDecoder

    init(
        persistence: PersistenceController,
        storagePaths: StoragePaths,
        keyStore: KeychainKeyStore,
        cryptoService: CryptoEnvelopeService,
        storageClient: any MediaStorageClient,
        fileManager: FileManager = .default
    ) {
        self.persistence = persistence
        self.storagePaths = storagePaths
        self.keyStore = keyStore
        self.cryptoService = cryptoService
        self.storageClient = storageClient
        self.fileManager = fileManager
        self.jsonDecoder = JSONDecoder()
    }

    func download(videoId: String, profileId: UUID) async throws -> RemoteVideoModel {
        if let task = inFlight[videoId] {
            return try await task.value
        }

        let task = Task<RemoteVideoModel, Error> {
            try await self.executeDownload(videoId: videoId, profileId: profileId)
        }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        return try await task.value
    }

    private func executeDownload(videoId: String, profileId: UUID) async throws -> RemoteVideoModel {
        let input = try await prepareDownload(videoId: videoId)

        do {
            let (parentKeys, wrapKeys) = try fetchParentCredentials()
            let encryptedMedia = try await fetchMediaData(
                key: input.blobKey,
                url: input.blobURL
            )
            let thumbData = try? await fetchThumbnailData(
                key: input.thumbKey,
                url: input.thumbURL
            )
            let mediaKey = try unwrapMediaKey(message: input.message, parentKeys: parentKeys, wrapKeys: wrapKeys)
            let decryptedMedia = try decryptMedia(data: encryptedMedia, message: input.message, mediaKey: mediaKey)

            return try await storeDownloadedMedia(
                input: input,
                profileId: profileId,
                mediaData: decryptedMedia,
                thumbData: thumbData
            )
        } catch {
            logger.error("Failed to download shared video \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await recordFailure(videoId: videoId, error: error)
            throw error
        }
    }

    private func prepareDownload(videoId: String) async throws -> DownloadInput {
        let context = persistence.newBackgroundContext()

        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request = RemoteVideoEntity.fetchRequest()
                    request.predicate = NSPredicate(format: "videoId == %@", videoId)
                    request.fetchLimit = 1

                    guard let entity = try context.fetch(request).first else {
                        throw DownloadError.videoRecordMissing
                    }

                    if entity.status == RemoteVideoModel.Status.revoked.rawValue ||
                        entity.status == RemoteVideoModel.Status.deleted.rawValue {
                        throw DownloadError.videoRecordMissing
                    }

                    guard let metadataString = entity.metadataJSON,
                          let metadataData = metadataString.data(using: .utf8)
                    else {
                        throw DownloadError.metadataCorrupted
                    }
                    let message = try self.jsonDecoder.decode(VideoShareMessage.self, from: metadataData)

                    let blobURL = URL(string: message.blob.url) ?? URL(string: entity.blobURL ?? "")
                    let thumbURL = URL(string: message.thumb.url) ?? URL(string: entity.thumbURL ?? "")

                    entity.status = RemoteVideoModel.Status.downloading.rawValue
                    entity.downloadError = nil

                    try context.save()

                    let input = DownloadInput(
                        videoId: videoId,
                        message: message,
                        blobURL: blobURL,
                        thumbURL: thumbURL,
                        blobKey: message.blob.key,
                        thumbKey: message.thumb.key,
                        previousMediaPath: entity.localMediaPath,
                        previousThumbPath: entity.localThumbPath
                    )
                    continuation.resume(returning: input)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchParentCredentials() throws -> (nostr: NostrKeyPair, wrap: ParentWrapKeyPair) {
        guard let nostr = try keyStore.fetchKeyPair(role: .parent) else {
            throw DownloadError.parentIdentityMissing
        }
        guard let wrap = try keyStore.fetchParentWrapKeyPair() else {
            throw DownloadError.parentIdentityMissing
        }
        return (nostr, wrap)
    }

    private func fetchMediaData(key: String?, url: URL?) async throws -> Data {
        guard key != nil || url != nil else {
            throw DownloadError.metadataCorrupted
        }
        do {
            return try await storageClient.downloadObject(
                key: key ?? "",
                fallbackURL: url
            )
        } catch let managed as ManagedStorageError {
            switch managed {
            case .downloadFailed(let failedURL),
                 .downloadHTTPFailure(let failedURL, _, _):
                throw DownloadError.mediaDownloadFailed(failedURL)
            case .downloadPresignFailed(let underlying):
                throw DownloadError.underlying(underlying)
            default:
                throw DownloadError.underlying(managed)
            }
        } catch {
            if let url {
                throw DownloadError.mediaDownloadFailed(url)
            } else {
                throw error
            }
        }
    }

    private func fetchThumbnailData(key: String?, url: URL?) async throws -> Data? {
        guard key != nil || url != nil else { return nil }
        do {
            return try await storageClient.downloadObject(
                key: key ?? "",
                fallbackURL: url
            )
        } catch let managed as ManagedStorageError {
            switch managed {
            case .downloadFailed(let failedURL),
                 .downloadHTTPFailure(let failedURL, _, _):
                throw DownloadError.thumbDownloadFailed(failedURL)
            case .downloadPresignFailed(let underlying):
                throw DownloadError.underlying(underlying)
            default:
                throw DownloadError.underlying(managed)
            }
        } catch {
            if let url {
                logger.warning("Thumbnail download failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw DownloadError.thumbDownloadFailed(url)
            } else {
                throw error
            }
        }
    }

    private func unwrapMediaKey(message: VideoShareMessage, parentKeys: NostrKeyPair, wrapKeys: ParentWrapKeyPair) throws -> Data {
        let crypto = message.crypto

        guard crypto.algMedia == cryptoService.mediaAlgorithmIdentifier else {
            throw DownloadError.unsupportedMediaAlgorithm(crypto.algMedia)
        }

        if let wrap = crypto.wrap {
            let wrapAlgorithm = crypto.algWrap ?? cryptoService.wrapAlgorithmIdentifier

            guard
                let ephemeral = decodeEnvelopeField(wrap.ephemeralPub),
                let wrapSalt = decodeEnvelopeField(wrap.wrapSalt),
                let wrapNonce = decodeEnvelopeField(wrap.wrapNonce),
                let wrappedKey = decodeEnvelopeField(wrap.keyWrapped)
            else {
                throw DownloadError.invalidEnvelope
            }

            let envelope = WrappedKeyEnvelope(
                algorithm: wrapAlgorithm,
                ephemeralPublicKey: ephemeral,
                wrapSalt: wrapSalt,
                wrapNonce: wrapNonce,
                keyCiphertext: wrappedKey
            )

            if let key = try? cryptoService.unwrapMediaKey(envelope, with: wrapKeys.privateKeyData) {
                return key
            } else {
                logger.warning("Failed to unwrap media key for \(message.videoId, privacy: .public); attempting direct key fallback.")
            }
        }

        if let directKey = crypto.mediaKey,
           let decoded = decodeEnvelopeField(directKey),
           decoded.count == 32 {
            return decoded
        }

        throw DownloadError.invalidEnvelope
    }

    private func decryptMedia(data: Data, message: VideoShareMessage, mediaKey: Data) throws -> Data {
        guard let nonce = decodeEnvelopeField(message.crypto.nonceMedia) else {
            throw DownloadError.invalidNonce
        }

        let nonceLength = nonce.count
        let tagLength = 16

        guard data.count > nonceLength + tagLength else {
            throw DownloadError.mediaDecryptionFailed
        }

        let cipherStart = data.index(data.startIndex, offsetBy: nonceLength)
        let cipherEnd = data.index(data.endIndex, offsetBy: -tagLength)

        let cipherText = data[cipherStart..<cipherEnd]
        let tag = data.suffix(tagLength)
        let nonceSlice = data.prefix(nonceLength)

        let payload = EncryptedMediaPayload(
            cipherText: Data(cipherText),
            nonce: Data(nonceSlice),
            tag: Data(tag)
        )

        do {
            return try cryptoService.decryptMedia(payload, key: mediaKey)
        } catch {
            throw DownloadError.mediaDecryptionFailed
        }
    }

    private func storeDownloadedMedia(
        input: DownloadInput,
        profileId: UUID,
        mediaData: Data,
        thumbData: Data?
    ) async throws -> RemoteVideoModel {
        let mediaURL = try resolveMediaURL(
            videoId: input.videoId,
            profileId: profileId,
            mime: input.message.blob.mime,
            existingPath: input.previousMediaPath
        )

        var resolvedThumbURL: URL?
        if let thumbData {
            resolvedThumbURL = try resolveThumbURL(
                videoId: input.videoId,
                profileId: profileId,
                mime: input.message.thumb.mime,
                existingPath: input.previousThumbPath
            )
        } else if let existingPath = input.previousThumbPath {
            resolvedThumbURL = storagePaths.rootURL.appendingPathComponent(existingPath)
        }

        do {
            try write(data: mediaData, to: mediaURL)
            if let thumbData, let destination = resolvedThumbURL {
                try write(data: thumbData, to: destination)
            }
        } catch {
            throw DownloadError.storageFailed(error.localizedDescription)
        }

        let relativeMediaPath = relativePath(for: mediaURL)
        let relativeThumbPath = resolvedThumbURL.flatMap(relativePath(for:))

        return try await updateEntity(videoId: input.videoId) { entity in
            entity.status = RemoteVideoModel.Status.downloaded.rawValue
            entity.localMediaPath = relativeMediaPath
            entity.localThumbPath = relativeThumbPath
            entity.lastDownloadedAt = Date()
            entity.downloadError = nil
        }
    }

    private func resolveMediaURL(
        videoId: String,
        profileId: UUID,
        mime: String,
        existingPath: String?
    ) throws -> URL {
        if let existingPath {
            return storagePaths.rootURL.appendingPathComponent(existingPath)
        }

        let ext = fileExtension(for: mime, defaultValue: "mp4")
        let directory = storagePaths
            .url(for: .media, profileId: profileId)
            .appendingPathComponent("Shared", isDirectory: true)
        try ensureDirectoryExists(at: directory)
        return directory.appendingPathComponent("\(videoId).\(ext)", isDirectory: false)
    }

    private func resolveThumbURL(
        videoId: String,
        profileId: UUID,
        mime: String,
        existingPath: String?
    ) throws -> URL? {
        if let existingPath {
            return storagePaths.rootURL.appendingPathComponent(existingPath)
        }

        let ext = fileExtension(for: mime, defaultValue: "jpg")
        let directory = storagePaths
            .url(for: .thumbs, profileId: profileId)
            .appendingPathComponent("Shared", isDirectory: true)
        try ensureDirectoryExists(at: directory)
        return directory.appendingPathComponent("\(videoId).\(ext)", isDirectory: false)
    }

    private func updateEntity(
        videoId: String,
        mutate: @escaping (RemoteVideoEntity) throws -> Void
    ) async throws -> RemoteVideoModel {
        let context = persistence.newBackgroundContext()

        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let request = RemoteVideoEntity.fetchRequest()
                    request.predicate = NSPredicate(format: "videoId == %@", videoId)
                    request.fetchLimit = 1

                    guard let entity = try context.fetch(request).first else {
                        throw DownloadError.videoRecordMissing
                    }

                    try mutate(entity)
                    try context.save()

                    guard let model = RemoteVideoModel(entity: entity) else {
                        throw DownloadError.metadataCorrupted
                    }

                    continuation.resume(returning: model)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func recordFailure(videoId: String, error: Swift.Error) async {
        let message: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            message = description
        } else {
            message = error.localizedDescription
        }

        do {
            _ = try await updateEntity(videoId: videoId) { entity in
                entity.status = RemoteVideoModel.Status.failed.rawValue
                entity.downloadError = message
            }
        } catch {
            logger.error("Failed to persist download error for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write(data: Data, to url: URL) throws {
        try ensureDirectoryExists(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try? fileManager.setAttributes(
            [FileAttributeKey.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func ensureDirectoryExists(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw DownloadError.storageFailed("Expected directory at \(url.lastPathComponent)")
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            #if os(iOS)
            try? fileManager.setAttributes(
                [FileAttributeKey.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            #endif
        }
    }

    private func fileExtension(for mime: String, defaultValue: String) -> String {
        switch mime.lowercased() {
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        case "video/x-m4v":
            return "m4v"
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        default:
            return defaultValue
        }
    }

    private func relativePath(for url: URL) -> String {
        let basePath = storagePaths.rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path

        if filePath.hasPrefix(basePath) {
            let startIndex = filePath.index(filePath.startIndex, offsetBy: basePath.count)
            var remainder = filePath[startIndex...]
            if remainder.first == "/" {
                remainder = remainder.dropFirst()
            }
            return remainder.isEmpty ? url.lastPathComponent : String(remainder)
        }

        return url.lastPathComponent
    }

    private func decodeEnvelopeField(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: trimmed) {
            return data
        }

        if let normalized = normalizeBase64URL(trimmed),
           let data = Data(base64Encoded: normalized) {
            return data
        }

        return Data(hexString: trimmed)
    }

    private func normalizeBase64URL(_ value: String) -> String? {
        guard value.contains("-") || value.contains("_") else { return nil }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding > 0, padding < 4 {
            base64.append(String(repeating: "=", count: padding))
        }
        return base64
    }
}
