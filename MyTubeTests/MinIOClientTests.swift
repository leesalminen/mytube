import Foundation
import Testing
@testable import MyTube

final class MinIOClientTests {
    @Test("uploadObject signs request and returns key")
    func testUploadObject() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        var capturedRequest: URLRequest?

        let apiBase = URL(string: "https://example.com")!
        let client = MinIOClient(
            configuration: MinIOConfiguration(
                apiBaseURL: apiBase,
                bucket: "mytube",
                accessKey: "access",
                secretKey: "secret"
            ),
            session: session
        )

        let payload = Data("test-payload".utf8)
        let suggestedKey = "videos/npub1/test-video/media.bin"

        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let result = try await client.uploadObject(
            data: payload,
            contentType: "application/octet-stream",
            suggestedKey: suggestedKey
        )

        let request = try #require(capturedRequest)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://example.com/mytube/\(suggestedKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "Content-Length") == String(payload.count))
        let amzDate = request.value(forHTTPHeaderField: "x-amz-date")
        #expect(amzDate?.count == 16) // yyyyMMdd'T'HHmmss'Z'
        let payloadHash = request.value(forHTTPHeaderField: "x-amz-content-sha256")
        #expect(payloadHash?.count == 64)
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(authorization.contains("AWS4-HMAC-SHA256"))
        #expect(authorization.contains("Credential=access/"))

        #expect(result.key == suggestedKey)
        #expect(result.accessURL?.absoluteString == "https://example.com/mytube/\(suggestedKey)")
    }
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
