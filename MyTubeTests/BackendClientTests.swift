//
//  BackendClientTests.swift
//  MyTubeTests
//
//  Created by Codex on 03/09/26.
//

import XCTest
@testable import MyTube

final class BackendClientTests: XCTestCase {
    override func tearDown() {
        BackendClientURLProtocol.reset()
        super.tearDown()
    }

    func testChallengeResponseParsesFractionalSeconds() throws {
        let json = """
        {
            "challenge": "abc123",
            "expires_at": "2025-11-01T12:01:03.000Z"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ChallengeResponse.self, from: json)
        XCTAssertEqual(response.challenge, "abc123")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: response.expiresAt
        )
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 11)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 12)
        XCTAssertEqual(components.minute, 1)
        XCTAssertEqual(components.second, 3)
    }

    func testEntitlementResponseAcceptsMixedFieldFormats() throws {
        let json = """
        {
            "plan": "trial",
            "status": "active",
            "expires_at": "2025-02-28T18:42:10.000Z",
            "quota_bytes": 53687091200,
            "usedBytes": "0"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(EntitlementResponse.self, from: json)
        XCTAssertEqual(response.plan, "trial")
        XCTAssertEqual(response.status, "active")
        XCTAssertEqual(response.quotaBytes, "53687091200")
        XCTAssertEqual(response.usedBytes, "0")
        XCTAssertNotNil(response.expiresAt)
    }

    func testFetchEntitlementRetriesAfter401AndCaches() async throws {
        BackendClientURLProtocol.reset()
        BackendClientURLProtocol.enqueue { request in
            XCTAssertEqual(request.url?.path, "/auth/challenge")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = """
            {"challenge":"first","expires_at":"2025-11-01T12:01:03.000Z"}
            """.data(using: .utf8)!
            return (200, ["Content-Type": "application/json"], body)
        }
        BackendClientURLProtocol.enqueue { request in
            XCTAssertEqual(request.url?.path, "/entitlement")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = """
            {"error":"unauthorized"}
            """.data(using: .utf8)!
            return (401, ["Content-Type": "application/json"], body)
        }
        BackendClientURLProtocol.enqueue { request in
            XCTAssertEqual(request.url?.path, "/auth/challenge")
            let body = """
            {"challenge":"second","expires_at":"2025-11-01T12:05:03.000Z"}
            """.data(using: .utf8)!
            return (200, ["Content-Type": "application/json"], body)
        }
        BackendClientURLProtocol.enqueue { request in
            XCTAssertEqual(request.url?.path, "/entitlement")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = """
            {
                "plan": "trial",
                "status": "active",
                "expires_at": "2025-03-01T00:00:00.000Z",
                "quota_bytes": "53687091200",
                "used_bytes": "0"
            }
            """.data(using: .utf8)!
            return (200, ["Content-Type": "application/json"], body)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendClientURLProtocol.self]
        let session = URLSession(configuration: config)

        let keyStore = KeychainKeyStore(service: "com.mytube.tests.backendclient.\(UUID().uuidString)")
        defer { try? keyStore.removeAll() }

        let client = BackendClient(
            baseURL: URL(string: "https://example.com")!,
            keyStore: keyStore,
            urlSession: session
        )

        let entitlement = try await client.fetchEntitlement(forceRefresh: true)
        XCTAssertEqual(entitlement.plan, "trial")
        XCTAssertEqual(entitlement.status, "active")
        XCTAssertNotNil(entitlement.expiresAt)

        // Subsequent call should hit cache and avoid the network.
        BackendClientURLProtocol.expectNoFurtherRequests()
        let cached = try await client.fetchEntitlement()
        XCTAssertEqual(cached.plan, "trial")
        XCTAssertEqual(cached.status, "active")
    }

    func testAuthorizationHeaderEncodesPathAndQuery() throws {
        let keyStore = KeychainKeyStore(service: "com.mytube.tests.nip98.\(UUID().uuidString)")
        defer { try? keyStore.removeAll() }

        let signer = NIP98Signer(keyStore: keyStore)
        let url = URL(string: "https://api.example.com/presign/upload?foo=bar&baz=1")!
        let header = try signer.authorizationHeader(
            method: "post",
            url: url,
            challenge: "challenge-token",
            body: Data("{}".utf8)
        )

        XCTAssertTrue(header.hasPrefix("Nostr "))
        let payloadBase64 = String(header.dropFirst("Nostr ".count))
        let payloadData = try XCTUnwrap(Data(base64Encoded: payloadBase64))
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])

        XCTAssertEqual(jsonObject["kind"] as? Int, 27235)

        let content = try XCTUnwrap(jsonObject["content"] as? String)
        XCTAssertTrue(content.contains("url=/presign/upload?foo=bar&baz=1"), "Content should contain path and query: \(content)")
        XCTAssertTrue(content.contains("method=POST"), "Content should uppercase method: \(content)")

        let tags = try XCTUnwrap(jsonObject["tags"] as? [[Any]])
        func value(for name: String) -> String? {
            tags.first { ($0.first as? String) == name }?.dropFirst().first as? String
        }

        XCTAssertEqual(value(for: "u"), url.absoluteString)
        XCTAssertEqual(value(for: "method"), "POST")
        XCTAssertEqual(value(for: "challenge"), "challenge-token")

        // payload tag should be present because we provided a body
        let payloadValue = value(for: "payload")
        XCTAssertNotNil(payloadValue)
        XCTAssertEqual(payloadValue?.count, 64)
    }
}

private final class BackendClientURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, [String: String], Data)

    private static let queue = DispatchQueue(label: "BackendClientURLProtocol.queue")
    private static var handlers: [Handler] = []
    private static var allowRequests = true

    static func reset() {
        queue.sync {
            Self.handlers.removeAll()
            Self.allowRequests = true
        }
    }

    static func enqueue(_ handler: @escaping Handler) {
        queue.sync {
            Self.handlers.append(handler)
        }
    }

    static func expectNoFurtherRequests() {
        queue.sync {
            Self.handlers.removeAll()
            Self.allowRequests = false
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let work: Handler? = BackendClientURLProtocol.queue.sync {
            if !Self.allowRequests {
                return nil
            }
            guard !Self.handlers.isEmpty else {
                return nil
            }
            return Self.handlers.removeFirst()
        }

        guard let handler = work else {
            client?.urlProtocol(self, didFailWithError: BackendClientTestError.unexpectedRequest(request))
            return
        }

        do {
            let (status, headers, data) = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: BackendClientTestError.invalidResponse)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op
    }
}

private enum BackendClientTestError: Error, CustomStringConvertible {
    case unexpectedRequest(URLRequest)
    case invalidResponse

    var description: String {
        switch self {
        case .unexpectedRequest(let request):
            return "Unexpected request: \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "<nil>")"
        case .invalidResponse:
            return "Failed to create HTTPURLResponse for test handler."
        }
    }
}
