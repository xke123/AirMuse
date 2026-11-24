import Testing
import Foundation
@testable import Domain
@testable import Infrastructure

@Suite("HTTPClientTests")
struct HTTPClientTests {
    @Test func httpClientMapsErrors() async {
        let transport = MockHTTPTransport { req, _, _ in
            if req.url.path.contains("403") {
                return HTTPResponse(statusCode: 403, data: Data(), url: req.url)
            }
            return HTTPResponse(statusCode: 401, data: Data(), url: req.url)
        }
        let client = HTTPClient(transport: transport, clock: TestClock())
        let req403 = HTTPRequest(
            url: URL(string: "https://example.com/403")!,
            policy: RequestPolicy(authScope: .publicCatalog(providerID: "apple_music", storefront: "cn"))
        )
        await #expect(throws: CoreError.forbidden(nil)) {
            _ = try await client.send(req403)
        }
    }

    @Test func httpClientMaps401OfflineTimeoutAndDecode() async {
        let transport = MockHTTPTransport { req, _, _ in
            if req.url.path.contains("offline") {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            }
            if req.url.path.contains("timeout") {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
            if req.url.path.contains("badjson") {
                return HTTPResponse(statusCode: 200, data: Data("bad".utf8), url: req.url)
            }
            return HTTPResponse(statusCode: 401, data: Data(), url: req.url)
        }
        let client = HTTPClient(transport: transport, clock: TestClock())

        let clientReq = HTTPRequest(
            url: URL(string: "https://example.com/401")!,
            policy: RequestPolicy(maxRetries: 0, authScope: .clientRequired(providerID: "apple_music", storefront: "cn"))
        )
        await #expect(throws: CoreError.clientCredentialInvalid) {
            _ = try await client.send(clientReq)
        }

        let ctx = SessionContext(providerID: "apple_music", accountID: "a1", storefront: "cn", sessionID: UUID(), generation: 1)
        let userReq = HTTPRequest(
            url: URL(string: "https://example.com/401")!,
            policy: RequestPolicy(maxRetries: 0, authScope: .userRequired(ctx))
        )
        await #expect(throws: CoreError.userCredentialInvalid) {
            _ = try await client.send(userReq)
        }

        let offReq = HTTPRequest(
            url: URL(string: "https://example.com/offline")!,
            policy: RequestPolicy(maxRetries: 0, authScope: .publicCatalog(providerID: "apple_music", storefront: "cn"))
        )
        await #expect(throws: CoreError.offline) {
            _ = try await client.send(offReq)
        }

        let toReq = HTTPRequest(
            url: URL(string: "https://example.com/timeout")!,
            policy: RequestPolicy(maxRetries: 0, authScope: .publicCatalog(providerID: "apple_music", storefront: "cn"))
        )
        await #expect(throws: CoreError.timeout) {
            _ = try await client.send(toReq)
        }
    }

    @Test func httpClientDeduplicatesAndIsolatesCancellation() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let transport = MockHTTPTransport { req, _, _ in
            for await _ in gate.stream { break }
            return HTTPResponse(statusCode: 200, data: Data("ok".utf8), url: req.url)
        }
        let client = HTTPClient(transport: transport, clock: TestClock())
        let req = HTTPRequest(
            url: URL(string: "https://example.com/shared")!,
            policy: RequestPolicy(authScope: .publicCatalog(providerID: "apple_music", storefront: "cn"))
        )

        var tasks: [Task<HTTPResponse, Error>] = []
        for _ in 0..<10 {
            tasks.append(Task { try await client.send(req) })
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.callCount == 1)

        tasks[0].cancel()
        gate.continuation.yield(())
        gate.continuation.finish()

        for i in 1..<10 {
            let resp = try await tasks[i].value
            #expect(resp.data == Data("ok".utf8))
        }
        #expect(await transport.callCount == 1)
    }

    @Test func httpClient429RetryAfterAndSideEffectNoRetry() async throws {
        let clock = TestClock()
        let transport = MockHTTPTransport { req, _, idx in
            if idx == 1 {
                return HTTPResponse(statusCode: 429, headers: ["Retry-After": "1"], data: Data(), url: req.url)
            }
            return HTTPResponse(statusCode: 200, data: Data("ok".utf8), url: req.url)
        }
        let client = HTTPClient(transport: transport, clock: clock)
        let req = HTTPRequest(
            url: URL(string: "https://example.com/rl")!,
            policy: RequestPolicy(totalDeadlineSeconds: 10, maxRetries: 2, authScope: .publicCatalog(providerID: "apple_music", storefront: "cn"))
        )
        let task = Task { try await client.send(req) }
        try await Task.sleep(for: .milliseconds(50))
        clock.advance(seconds: 1.1)
        let res = try await task.value
        #expect(res.statusCode == 200)
        #expect(await transport.callCount == 2)

        let postTransport = MockHTTPTransport { req, _, _ in
            HTTPResponse(statusCode: 503, data: Data(), url: req.url)
        }
        let postClient = HTTPClient(transport: postTransport, clock: clock)
        let postReq = HTTPRequest(
            method: .post,
            url: URL(string: "https://example.com/post")!,
            policy: RequestPolicy(maxRetries: 3, authScope: .publicCatalog(providerID: "apple_music", storefront: "cn"), isSideEffecting: true)
        )
        await #expect(throws: CoreError.server(statusCode: 503, message: nil)) {
            _ = try await postClient.send(postReq)
        }
        #expect(await postTransport.callCount == 1)
    }
}
