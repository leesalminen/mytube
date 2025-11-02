//
//  StorageRouter.swift
//  MyTube
//
//  Created by Codex on 01/07/26.
//

import Foundation

actor StorageRouter: MediaStorageClient {
    private var client: any MediaStorageClient

    init(initialClient: any MediaStorageClient) {
        self.client = initialClient
    }

    func updateClient(_ client: any MediaStorageClient) {
        self.client = client
    }

    @discardableResult
    func uploadObject(
        data: Data,
        contentType: String,
        suggestedKey: String?
    ) async throws -> StorageUploadResult {
        try await client.uploadObject(
            data: data,
            contentType: contentType,
            suggestedKey: suggestedKey
        )
    }

    func objectURL(for key: String) async throws -> URL {
        try await client.objectURL(for: key)
    }

    func downloadObject(key: String, fallbackURL: URL?) async throws -> Data {
        try await client.downloadObject(key: key, fallbackURL: fallbackURL)
    }
}
