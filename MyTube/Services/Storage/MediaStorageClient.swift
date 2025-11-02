//
//  MediaStorageClient.swift
//  MyTube
//
//  Created by Codex on 01/07/26.
//

import Foundation

/// Describes the outcome of an upload to remote object storage.
struct StorageUploadResult: Sendable {
    /// Canonical key/path identifying the object within the remote bucket.
    let key: String
    /// Optional access URL that can be shared with other devices.
    /// Managed storage implementations may return a short-lived pre-signed URL.
    let accessURL: URL?
}

/// Abstraction over remote object storage used for encrypted media blobs and thumbnails.
protocol MediaStorageClient: Sendable {
    @discardableResult
    func uploadObject(
        data: Data,
        contentType: String,
        suggestedKey: String?
    ) async throws -> StorageUploadResult

    func objectURL(for key: String) async throws -> URL

    func downloadObject(key: String, fallbackURL: URL?) async throws -> Data
}
