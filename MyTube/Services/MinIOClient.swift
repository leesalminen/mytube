//
//  MinIOClient.swift
//  MyTube
//
//  Created by Codex on 10/26/25.
//

import CryptoKit
import Foundation

struct MinIOConfiguration {
    let apiBaseURL: URL
    let bucket: String
    let accessKey: String
    let secretKey: String
    let region: String
    let pathStyle: Bool

    init(
        apiBaseURL: URL,
        bucket: String,
        accessKey: String,
        secretKey: String,
        region: String = "us-east-1",
        pathStyle: Bool = true
    ) {
        self.apiBaseURL = apiBaseURL
        self.bucket = bucket
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.pathStyle = pathStyle
    }

    var basicAuthorizationHeader: String {
        let credentials = "\(accessKey):\(secretKey)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    func objectURL(for key: String) -> URL {
        if pathStyle {
            let bucketBase = apiBaseURL
                .appendingPathComponent(bucket, isDirectory: true)
            return URL(string: key, relativeTo: bucketBase)?.absoluteURL ?? bucketBase.appendingPathComponent(key)
        }

        guard var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            return apiBaseURL.appendingPathComponent(key)
        }

        if let host = apiBaseURL.host, !host.isEmpty {
            components.host = "\(bucket).\(host)"
        } else {
            components.host = bucket
        }

        let basePath = apiBaseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefixed = basePath.isEmpty ? "" : "/\(basePath)"
        components.path = "\(prefixed)/\(key)"
        components.port = apiBaseURL.port
        return components.url ?? apiBaseURL.appendingPathComponent(key)
    }
}

struct MinIOUploadInitRequest: Encodable {
    let videoId: String
    let ownerChild: String
    let size: Int
    let mime: String

    private enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case ownerChild = "owner_child"
        case size
        case mime
    }
}

struct MinIOUploadInitResponse: Decodable {
    let putURL: URL
    let key: String
    let thumbPutURL: URL
    let thumbKey: String

    private enum CodingKeys: String, CodingKey {
        case putURL = "put_url"
        case key
        case thumbPutURL = "thumb_put_url"
        case thumbKey = "thumb_key"
    }
}

struct MinIOUploadCommitRequest: Encodable {
    let videoId: String
    let key: String
    let thumbKey: String

    private enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case key
        case thumbKey = "thumb_key"
    }
}

struct MinIODeleteRequest: Encodable {
    let key: String
    let thumbKey: String

    private enum CodingKeys: String, CodingKey {
        case key
        case thumbKey = "thumb_key"
    }
}

enum MinIOClientError: Error {
    case invalidResponse
    case serverError(statusCode: Int, body: String)
}

actor MinIOClient {
    private let configuration: MinIOConfiguration
    private let session: URLSession
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    init(configuration: MinIOConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.outputFormatting = [.sortedKeys]
        self.jsonDecoder = JSONDecoder()
    }

    func objectURL(for key: String) -> URL {
        configuration.objectURL(for: key)
    }

    @discardableResult
    func uploadObject(
        data: Data,
        contentType: String,
        suggestedKey: String? = nil
    ) async throws -> StorageUploadResult {
        let objectKey = suggestedKey ?? UUID().uuidString
        let url = configuration.objectURL(for: objectKey)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

        let payloadHash = sha256Hex(data)
        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let hostHeader: String
        if let host = request.url?.host, let port = request.url?.port {
            hostHeader = "\(host):\(port)"
        } else {
            hostHeader = request.url?.host ?? configuration.apiBaseURL.host ?? ""
        }

        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let canonicalHeaders = [
            "content-type:\(contentType)",
            "host:\(hostHeader)",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(amzDate)"
        ].joined(separator: "\n") + "\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            "PUT",
            canonicalURI.addingPercentEncoding(withAllowedCharacters: .awsURIAllowed) ?? canonicalURI,
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(configuration.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(
            secretKey: configuration.secretKey,
            dateStamp: dateStamp,
            region: configuration.region,
            service: "s3"
        )
        let signature = hmacSHA256(key: signingKey, data: stringToSign).map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 Credential=\(configuration.accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MinIOClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw MinIOClientError.serverError(statusCode: httpResponse.statusCode, body: body)
        }

        let publicURL = configuration.objectURL(for: objectKey)
        return StorageUploadResult(key: objectKey, accessURL: publicURL)
    }

    func downloadObject(key: String) async throws -> Data {
        let url = configuration.objectURL(for: key)
        return try await downloadSignedRequest(url: url)
    }

    func downloadObject(url: URL) async throws -> Data {
        if let key = extractObjectKey(from: url) {
            return try await downloadObject(key: key)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MinIOClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MinIOClientError.serverError(statusCode: httpResponse.statusCode, body: body)
        }
        return data
    }

    func initializeUpload(request: MinIOUploadInitRequest) async throws -> MinIOUploadInitResponse {
        let (data, response) = try await sendRequest(
            path: "/upload/init",
            method: "POST",
            body: request
        )
        guard response.statusCode == 200 else {
            throw try decodeError(statusCode: response.statusCode, data: data)
        }
        return try jsonDecoder.decode(MinIOUploadInitResponse.self, from: data)
    }

    func commitUpload(request: MinIOUploadCommitRequest) async throws {
        let (data, response) = try await sendRequest(
            path: "/upload/commit",
            method: "POST",
            body: request
        )
        guard (200..<300).contains(response.statusCode) else {
            throw try decodeError(statusCode: response.statusCode, data: data)
        }
    }

    func deleteMedia(request: MinIODeleteRequest) async throws {
        let (data, response) = try await sendRequest(
            path: "/media",
            method: "DELETE",
            body: request
        )
        guard (200..<300).contains(response.statusCode) else {
            throw try decodeError(statusCode: response.statusCode, data: data)
        }
    }

    private func sendRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: path, relativeTo: configuration.apiBaseURL) ?? configuration.apiBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.basicAuthorizationHeader, forHTTPHeaderField: "Authorization")

        if let body {
            request.httpBody = try jsonEncoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MinIOClientError.invalidResponse
        }
        return (data, httpResponse)
    }

    private func decodeError(statusCode: Int, data: Data) throws -> Error {
        let body = String(data: data, encoding: .utf8) ?? ""
        return MinIOClientError.serverError(statusCode: statusCode, body: body)
    }

    private func downloadSignedRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let payloadHash = sha256Hex(Data())
        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let hostHeader: String
        if let host = request.url?.host, let port = request.url?.port {
            hostHeader = "\(host):\(port)"
        } else {
            hostHeader = request.url?.host ?? configuration.apiBaseURL.host ?? ""
        }

        let canonicalHeaders = [
            "host:\(hostHeader)",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(amzDate)"
        ].joined(separator: "\n") + "\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            "GET",
            url.path.addingPercentEncoding(withAllowedCharacters: .awsURIAllowed) ?? url.path,
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(configuration.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(
            secretKey: configuration.secretKey,
            dateStamp: dateStamp,
            region: configuration.region,
            service: "s3"
        )
        let signature = hmacSHA256(key: signingKey, data: stringToSign).map { String(format: "%02x", $0) }.joined()
        let authorization = "AWS4-HMAC-SHA256 Credential=\(configuration.accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MinIOClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MinIOClientError.serverError(statusCode: httpResponse.statusCode, body: body)
        }
        return data
    }

    private func extractObjectKey(from url: URL) -> String? {
        guard
            let targetHost = url.host,
            let configuredHost = configuration.apiBaseURL.host,
            targetHost.caseInsensitiveCompare(configuredHost) == .orderedSame
        else {
            return nil
        }

        let basePath = normalizedBasePath()
        let urlPath = url.path

        guard urlPath.hasPrefix(basePath) else { return nil }

        var remainder = urlPath.dropFirst(basePath.count)
        if remainder.first == "/" {
            remainder = remainder.dropFirst()
        }
        return remainder.isEmpty ? nil : String(remainder)
    }

    private func normalizedBasePath() -> String {
        var components: [String] = []
        let apiPath = configuration.apiBaseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !apiPath.isEmpty {
            components.append(apiPath)
        }
        components.append(configuration.bucket)
        return "/" + components.joined(separator: "/")
    }
}

// MARK: - MediaStorageClient

extension MinIOClient: MediaStorageClient {
    func objectURL(for key: String) async throws -> URL {
        configuration.objectURL(for: key)
    }

    func downloadObject(key: String, fallbackURL: URL?) async throws -> Data {
        do {
            return try await self.downloadObject(key: key)
        } catch {
            guard let url = fallbackURL else { throw error }
            return try await downloadObject(url: url)
        }
    }
}

extension MinIOClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "MinIO returned an invalid response."
        case .serverError(let statusCode, let body):
            if body.isEmpty {
                return "MinIO request failed with status \(statusCode)."
            }
            return "MinIO request failed (\(statusCode)): \(body)"
        }
    }
}

// MARK: - AWS Signature Helpers

private extension MinIOClient {
    static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func deriveSigningKey(secretKey: String, dateStamp: String, region: String, service: String) -> Data {
        let kSecret = "AWS4\(secretKey)".data(using: .utf8)!
        let kDate = hmacSHA256(key: kSecret, data: dateStamp)
        let kRegion = hmacSHA256(key: kDate, data: region)
        let kService = hmacSHA256(key: kRegion, data: service)
        return hmacSHA256(key: kService, data: "aws4_request")
    }

    func hmacSHA256(key: Data, data: String) -> Data {
        let keySymmetric = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: keySymmetric)
        return Data(signature)
    }
}

private extension CharacterSet {
    static let awsURIAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":")
        return allowed
    }()
}
