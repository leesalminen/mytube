//
//  ManagedStorageClient.swift
//  MyTube
//
//  Created by Codex on 01/07/26.
//

import Foundation
import OSLog

enum ManagedStorageError: Error {
    case presignFailed(Error)
    case uploadFailed(Error)
    case uploadHTTPFailure(status: Int, body: String)
    case downloadFailed(URL)
    case downloadHTTPFailure(url: URL, status: Int, body: String)
    case downloadPresignFailed(Error)
}

actor ManagedStorageClient: MediaStorageClient {
    private let backend: BackendClient
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.mytube", category: "ManagedStorageClient")

    init(backend: BackendClient, urlSession: URLSession = .shared) {
        self.backend = backend
        self.urlSession = urlSession
    }

    @discardableResult
    func uploadObject(
        data: Data,
        contentType: String,
        suggestedKey: String?
    ) async throws -> StorageUploadResult {
        let filename: String
        if let suggestedKey,
           let name = suggestedKey.split(separator: "/").last {
            filename = String(name)
        } else {
            filename = UUID().uuidString
        }

        let presign: PresignUploadResponse
        do {
            presign = try await backend.presignUpload(
                request: PresignUploadRequest(
                    filename: filename,
                    contentType: contentType,
                    sizeBytes: data.count
                )
            )
        } catch {
            logger.error("Upload presign failed: \(error.localizedDescription, privacy: .public)")
            throw ManagedStorageError.presignFailed(error)
        }

        var uploadRequest = URLRequest(url: presign.url)
        uploadRequest.httpMethod = "PUT"
        presign.headers.forEach { key, value in
            uploadRequest.setValue(value, forHTTPHeaderField: key)
        }
        uploadRequest.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

        do {
            let (responseData, response) = try await urlSession.upload(for: uploadRequest, from: data)
            if let http = response as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else {
                    let bodyString = String(data: responseData, encoding: .utf8) ?? ""
                    logger.error("Upload failed with status \(http.statusCode) body=\(bodyString, privacy: .public)")
                    throw ManagedStorageError.uploadHTTPFailure(status: http.statusCode, body: bodyString)
                }
                logger.info("Uploaded object \(presign.key, privacy: .public) with status \(http.statusCode)")
            }
        } catch let managed as ManagedStorageError {
            throw managed
        } catch {
            logger.error("Upload transport error: \(error.localizedDescription, privacy: .public)")
            throw ManagedStorageError.uploadFailed(error)
        }

        // Return a download URL immediately for DM payloads. It may be short-lived.
        let download: PresignDownloadResponse?
        do {
            download = try await backend.presignDownload(key: presign.key)
        } catch {
            logger.debug("Presign download failed after upload for key \(presign.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            download = nil
        }

        return StorageUploadResult(
            key: presign.key,
            accessURL: download?.url
        )
    }

    func objectURL(for key: String) async throws -> URL {
        do {
            let response = try await backend.presignDownload(key: key)
            return response.url
        } catch {
            logger.error("Presign download failed for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ManagedStorageError.downloadPresignFailed(error)
        }
    }

    func downloadObject(key: String, fallbackURL: URL?) async throws -> Data {
        if let fallbackURL {
            if let data = try? await fetchData(url: fallbackURL) {
                return data
            }
            logger.debug("Fallback download failed for \(fallbackURL.absoluteString, privacy: .public)")
        }
        do {
            let response = try await backend.presignDownload(key: key)
            return try await fetchData(url: response.url)
        } catch {
            logger.error("Presign download failed for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ManagedStorageError.downloadPresignFailed(error)
        }
    }

    private func fetchData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ManagedStorageError.downloadFailed(url)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Download failed with status \(http.statusCode) url=\(url.absoluteString, privacy: .public) body=\(body, privacy: .public)")
            throw ManagedStorageError.downloadHTTPFailure(url: url, status: http.statusCode, body: body)
        }
        return data
    }
}

extension ManagedStorageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .presignFailed(let error):
            return "Managed storage presign failed: \(error.localizedDescription)"
        case .uploadFailed(let error):
            return "Managed storage upload failed: \(error.localizedDescription)"
        case .uploadHTTPFailure(let status, let body):
            if body.isEmpty {
                return "Managed storage upload failed with status \(status)."
            }
            return "Managed storage upload failed (\(status)): \(body)"
        case .downloadFailed(let url):
            return "Managed storage download failed for \(url.absoluteString)."
        case .downloadHTTPFailure(let url, let status, let body):
            if body.isEmpty {
                return "Managed storage download failed (\(status)) for \(url.absoluteString)."
            }
            return "Managed storage download failed (\(status)) for \(url.absoluteString): \(body)"
        case .downloadPresignFailed(let error):
            return "Managed storage download presign failed: \(error.localizedDescription)"
        }
    }
}
