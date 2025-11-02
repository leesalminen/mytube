//
//  BackendClient.swift
//  MyTube
//
//  Created by Codex on 01/07/26.
//

import Foundation
import OSLog

struct ChallengeResponse: Decodable {
    let challenge: String
    let expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case challenge
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        challenge = try container.decode(String.self, forKey: .challenge)
        let expiresString = try container.decode(String.self, forKey: .expiresAt)
        guard let parsed = ChallengeResponse.parseDate(expiresString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt,
                in: container,
                debugDescription: "Expected ISO8601 date, got \(expiresString)"
            )
        }
        expiresAt = parsed
    }

    private static func parseDate(_ value: String) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: value) {
            return date
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) {
            return date
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fallback.date(from: value)
    }
}

struct PresignUploadRequest: Encodable {
    let filename: String
    let contentType: String
    let sizeBytes: Int

    private enum CodingKeys: String, CodingKey {
        case filename
        case contentType = "content_type"
        case sizeBytes = "size_bytes"
    }
}

struct PresignUploadResponse: Decodable {
    let key: String
    let url: URL
    let headers: [String: String]
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case key
        case url
        case headers
        case expiresIn = "expires_in"
    }
}

struct PresignDownloadRequest: Encodable {
    let key: String
}

struct PresignDownloadResponse: Decodable {
    let url: URL
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case url
        case expiresIn = "expires_in"
    }
}

struct EntitlementResponse: Decodable {
    let plan: String
    let status: String
    let expiresAt: Date?
    let quotaBytes: String?
    let usedBytes: String?

    private static let logger = Logger(subsystem: "com.mytube", category: "BackendClient.Entitlement")

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)

        guard let planKey = FlexibleCodingKey(stringValue: "plan"),
              let statusKey = FlexibleCodingKey(stringValue: "status") else {
            throw DecodingError.keyNotFound(FlexibleCodingKey("plan"), DecodingError.Context(codingPath: [], debugDescription: "Missing plan/status keys"))
        }
        plan = try container.decode(String.self, forKey: planKey)
        status = try container.decode(String.self, forKey: statusKey)

        let expiresString = container.decodeOptionalString(forKeys: ["expires_at", "expiresAt"])
        expiresAt = EntitlementResponse.parseDate(from: expiresString)
        if let expiresString, expiresAt == nil {
            Self.logger.error("Failed to parse expires_at value: \(expiresString, privacy: .public)")
        }

        quotaBytes = container.decodeStringOrNumber(forKeys: ["quota_bytes", "quotaBytes"])
        usedBytes = container.decodeStringOrNumber(forKeys: ["used_bytes", "usedBytes"])
    }

    struct FlexibleCodingKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int?

        init(_ string: String) {
            self.stringValue = string
            self.intValue = nil
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.intValue = intValue
            self.stringValue = "\(intValue)"
        }
    }

    private static func parseDate(from string: String?) -> Date? {
        guard let string else { return nil }
        if string.isEmpty { return nil }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: string) {
            return date
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) {
            return date
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fallback.date(from: string)
    }
}

private extension KeyedDecodingContainer where Key == EntitlementResponse.FlexibleCodingKey {
    func decodeOptionalString(forKeys keys: [String]) -> String? {
        for key in keys {
            guard let codingKey = Key(stringValue: key) else { continue }
            if let value = try? decodeIfPresent(String.self, forKey: codingKey) {
                return value
            }
        }
        return nil
    }

    func decodeStringOrNumber(forKeys keys: [String]) -> String? {
        for key in keys {
            guard let codingKey = Key(stringValue: key) else { continue }
            if let stringValue = try? decodeIfPresent(String.self, forKey: codingKey) {
                return stringValue
            }
            if let intValue = try? decodeIfPresent(Int.self, forKey: codingKey) {
                return String(intValue)
            }
            if let doubleValue = try? decodeIfPresent(Double.self, forKey: codingKey) {
                return String(format: "%.0f", doubleValue)
            }
        }
        return nil
    }
}

enum BackendClientError: Error {
    case invalidResponse
    case httpFailure(status: Int, body: String)
}

actor BackendClient {
    enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    private struct ChallengeCache {
        let value: ChallengeResponse
    }

    private var baseURL: URL
    private let urlSession: URLSession
    private let nip98Signer: NIP98Signer
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let logger = Logger(subsystem: "com.mytube", category: "BackendClient")
    private let challengeSkew: TimeInterval = 5
    private let entitlementCacheDuration: TimeInterval = 60

    private var cachedChallenge: ChallengeCache?
    private var challengeTask: Task<ChallengeResponse, Error>?
    private var cachedEntitlement: EntitlementResponse?
    private var entitlementFetchedAt: Date?

    init(
        baseURL: URL,
        keyStore: KeychainKeyStore,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.nip98Signer = NIP98Signer(keyStore: keyStore)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func currentBaseURL() -> URL {
        baseURL
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
        invalidateChallenge()
        cachedEntitlement = nil
        entitlementFetchedAt = nil
    }

    func fetchEntitlement(forceRefresh: Bool = false) async throws -> EntitlementResponse {
        if !forceRefresh,
           let cachedEntitlement,
           let fetchedAt = entitlementFetchedAt,
           Date().timeIntervalSince(fetchedAt) < entitlementCacheDuration {
            logger.debug("Returning cached entitlement fetched at \(fetchedAt.timeIntervalSince1970, privacy: .public)")
            return cachedEntitlement
        }

        let response: EntitlementResponse = try await authorizedJSONRequest(
            method: .get,
            path: "entitlement",
            body: nil
        )
        logger.info("Fetched entitlement: \(response.status, privacy: .public) plan \(response.plan, privacy: .public)")
        cacheEntitlement(response)
        return response
    }

    func cachedEntitlementState() -> EntitlementResponse? {
        cachedEntitlement
    }

    private func cacheEntitlement(_ entitlement: EntitlementResponse) {
        cachedEntitlement = entitlement
        entitlementFetchedAt = Date()
    }

    func presignUpload(request: PresignUploadRequest) async throws -> PresignUploadResponse {
        let body = try encoder.encode(request)
        return try await authorizedJSONRequest(
            method: .post,
            path: "presign/upload",
            body: body
        )
    }

    func presignDownload(key: String) async throws -> PresignDownloadResponse {
        let body = try encoder.encode(PresignDownloadRequest(key: key))
        return try await authorizedJSONRequest(
            method: .post,
            path: "presign/download",
            body: body
        )
    }

    private func authorizedJSONRequest<Response: Decodable>(
        method: HTTPMethod,
        path: String,
        body: Data?
    ) async throws -> Response {
        var attempt = 0
        while true {
            do {
                var request = try await authorizedRequest(method: method, path: path, body: body)
                if let body {
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await urlSession.data(for: request)
                let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                if let http = response as? HTTPURLResponse {
                    logger.debug("Received \(http.statusCode) from \(method.rawValue) \(request.url?.absoluteString ?? "") body=\(bodyString, privacy: .public)")
                }
                try validate(response: response, data: data)
                do {
                    return try decoder.decode(Response.self, from: data)
                } catch {
                    logger.error("Decoding \(Response.self) failed: \(error.localizedDescription, privacy: .public) body=\(bodyString, privacy: .public)")
                    throw error
                }
            } catch BackendClientError.httpFailure(let status, let body) where status == 401 && attempt == 0 {
                logger.warning("Received 401 for \(method.rawValue, privacy: .public) \(path, privacy: .public). Body=\(body, privacy: .public). Invalidating challenge and retrying once.")
                invalidateChallenge()
                attempt += 1
                continue
            } catch {
                throw error
            }
        }
    }

    private func authorizedRequest(
        method: HTTPMethod,
        path: String,
        body: Data?
    ) async throws -> URLRequest {
        let url = resolve(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body

        let challenge = try await nextChallenge()
        logger.debug("Using challenge expiring at \(challenge.expiresAt, privacy: .public)")
        let header = try nip98Signer.authorizationHeader(
            method: method.rawValue,
            url: url,
            challenge: challenge.challenge,
            body: body
        )
        request.setValue(header, forHTTPHeaderField: "Authorization")
        if let body, let json = String(data: body, encoding: .utf8) {
            logger.debug("Prepared \(method.rawValue, privacy: .public) \(url.absoluteString, privacy: .public) body=\(json, privacy: .public)")
        } else {
            logger.debug("Prepared \(method.rawValue, privacy: .public) \(url.absoluteString, privacy: .public)")
        }
        return request
    }

    private func nextChallenge() async throws -> ChallengeResponse {
        if let cachedChallenge,
           cachedChallenge.value.expiresAt.timeIntervalSinceNow > challengeSkew {
            logger.debug("Reusing cached challenge expiring at \(cachedChallenge.value.expiresAt, privacy: .public)")
            return cachedChallenge.value
        }

        if let challengeTask {
            logger.debug("Awaiting in-flight challenge request")
            return try await challengeTask.value
        }

        let task = Task<ChallengeResponse, Error> {
            let response = try await self.requestChallenge()
            await self.storeChallenge(response)
            return response
        }
        challengeTask = task

        do {
            let response = try await task.value
            challengeTask = nil
            return response
        } catch {
            challengeTask = nil
            throw error
        }
    }

    private func requestChallenge() async throws -> ChallengeResponse {
        var request = URLRequest(url: resolve(path: "auth/challenge"))
        request.httpMethod = HTTPMethod.post.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        logger.debug("Requesting challenge from \(request.url?.absoluteString ?? "", privacy: .public)")
        let (data, response) = try await urlSession.data(for: request)
        let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        if let http = response as? HTTPURLResponse {
            logger.debug("Challenge response \(http.statusCode) body=\(bodyString, privacy: .public)")
        }
        try validate(response: response, data: data)
        let decoded: ChallengeResponse
        do {
            decoded = try decoder.decode(ChallengeResponse.self, from: data)
        } catch {
            logger.error("Failed to decode challenge: \(error.localizedDescription, privacy: .public) body=\(bodyString, privacy: .public)")
            throw error
        }
        logger.info("Received challenge expiring at \(decoded.expiresAt, privacy: .public)")
        return decoded
    }

    private func storeChallenge(_ challenge: ChallengeResponse) {
        cachedChallenge = ChallengeCache(value: challenge)
    }

    private func invalidateChallenge() {
        challengeTask?.cancel()
        challengeTask = nil
        cachedChallenge = nil
        logger.debug("Cleared cached challenge")
    }

    private func resolve(path: String) -> URL {
        if let url = URL(string: path), url.scheme != nil {
            return url
        }
        var cleaned = path
        if cleaned.hasPrefix("/") {
            cleaned.removeFirst()
        }
        return baseURL.appendingPathComponent(cleaned)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Backend request failed: \(http.statusCode) \(body, privacy: .public)")
            throw BackendClientError.httpFailure(status: http.statusCode, body: body)
        }
    }
}
